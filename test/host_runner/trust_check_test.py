import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "host-runner"))

import souls_house_runner as runner  # noqa: E402
from commands_test import IMAGE, FakeDocker  # noqa: E402


def payload(**overrides):
    base = {
        "container_name": "agent-pilot-1",
        "image": IMAGE,
        "env": {
            "SOULSHOUSE_PORTABLE_HOME_ID": "home-1234",
            "SOULSHOUSE_HOME_SYNC_STRATEGY": "standard",
            "SOULSHOUSE_HOME_SYNC_CONFIGURATION": '{"auto_commit_paths":["memory"]}',
            "SOULSHOUSE_GITHUB_IMPORT_REQUIRE_OAUTH_TRUST": "0",
        },
    }
    base.update(overrides)
    return base


class FakeExit:
    def __init__(self, code=0, stdout=""):
        self.code = code
        self.stdout = stdout
        self.calls = []

    def __call__(self, argv, timeout=120):
        self.calls.append(argv)
        return self.code, self.stdout


class RuntimeTrustCheckTest(unittest.TestCase):
    """docs/2026-10-10-vm-imports.md, point 5: the house's own trust check,
    run by the runner in the resident's image, values only from Rails."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.docker = FakeDocker(images=(IMAGE,))
        self.exit = FakeExit()
        self.host = runner.ResidentHost(self.dir, docker=self.docker, docker_exit=self.exit, sleep=lambda s: None)

    def test_it_runs_the_fixed_script_with_identity_and_chaos_read_only_and_only_the_given_values(self):
        result = self.host.check_runtime_trust(payload())
        self.assertEqual({"trust": "trusted", "exit": 0}, result)
        (argv,) = self.exit.calls
        self.assertEqual(["docker", "run", "--rm",
                          "-v", "agent-pilot-1-identity:/home/agent/identity:ro",
                          "-v", "agent-pilot-1-chaos:/home/agent/.chaos:ro",
                          "-e", "SOULSHOUSE_HOME_PROFILE=portable_v1",
                          "-e", "SOULSHOUSE_HOME_ROOT=/home/agent/identity",
                          "-e", "SOULSHOUSE_PORTABLE_HOME_ID=home-1234",
                          "-e", "SOULSHOUSE_HOME_SYNC_STRATEGY=standard",
                          "-e", 'SOULSHOUSE_HOME_SYNC_CONFIGURATION={"auto_commit_paths":["memory"]}',
                          "-e", "SOULSHOUSE_GITHUB_IMPORT_REQUIRE_OAUTH_TRUST=0",
                          "--entrypoint", "python3", IMAGE, "-c", runner.RUNTIME_TRUST_CHECK], argv)
        self.assertNotIn("--privileged", argv)
        self.assertFalse(any("docker.sock" in part for part in argv))

    def test_a_failed_check_is_untrusted_and_the_unsupported_runtime_is_said_plainly(self):
        self.exit.code = 78
        self.assertEqual("untrusted", self.host.check_runtime_trust(payload())["trust"])
        self.exit.code, self.exit.stdout = 79, "unsupported-managed-import-runtime\n"
        self.assertEqual({"trust": "unsupported"}, self.host.check_runtime_trust(payload()))
        self.exit.code, self.exit.stdout = 1, ""
        self.assertEqual("untrusted", self.host.check_runtime_trust(payload())["trust"])

    def test_a_check_that_did_not_finish_fails_the_command_rather_than_answer(self):
        self.exit.code = None
        with self.assertRaises(runner.CommandFailed):
            self.host.check_runtime_trust(payload())

    def test_with_no_chaos_home_yet_it_is_made_empty_and_untrusted_without_running_anything(self):
        docker = FakeDocker(images=(IMAGE,), fail=("volume inspect",))
        host = runner.ResidentHost(self.dir, docker=docker, docker_exit=self.exit, sleep=lambda s: None)
        self.assertEqual({"trust": "untrusted", "reason": "no_chaos_home"}, host.check_runtime_trust(payload()))
        self.assertIn(["docker", "volume", "create", "agent-pilot-1-chaos"], docker.calls)
        self.assertEqual([], self.exit.calls)

    def test_the_image_is_the_pinned_one_or_nothing_runs(self):
        host = runner.ResidentHost(self.dir, docker=FakeDocker(images=()), docker_exit=self.exit, sleep=lambda s: None)
        with self.assertRaises(runner.CommandFailed):
            host.check_runtime_trust(payload())
        self.assertEqual([], self.exit.calls)

    def test_values_are_checked_and_no_other_name_is_accepted(self):
        bad = [
            payload(container_name="../x"),
            payload(image="ubuntu:latest"),
            payload(env={**payload()["env"], "PATH": "/tmp"}),
            payload(env={key: value for key, value in payload()["env"].items() if key != "SOULSHOUSE_PORTABLE_HOME_ID"}),
            payload(env={**payload()["env"], "SOULSHOUSE_HOME_SYNC_STRATEGY": "rsync"}),
            payload(env={**payload()["env"], "SOULSHOUSE_GITHUB_IMPORT_REQUIRE_OAUTH_TRUST": "yes"}),
            payload(env={**payload()["env"], "SOULSHOUSE_PORTABLE_HOME_ID": "a\nb"}),
            payload(env="SOULSHOUSE_PORTABLE_HOME_ID=x"),
        ]
        for command in bad:
            with self.assertRaises(runner.BadCommand, msg=repr(command)):
                self.host.check_runtime_trust(command)
        self.assertEqual([], self.exit.calls)

    def test_the_runner_says_it_has_the_check_and_accepts_an_imported_homes_env(self):
        facts = runner.collect_facts(server_id_reader=lambda: 1, command_runner=lambda argv: None)
        self.assertEqual(runner.RUNTIME_TRUST_CHECK_VERSION, facts["runtime_trust_check"])
        env = {"TRIGGER_BEARER_TOKEN": "t", "SOULSHOUSE_HOME_ROOT": "/home/agent/identity",
               "SOULSHOUSE_GITHUB_IMPORT_ID": "7", "SOULSHOUSE_HOME_SYNC_CONFIGURATION": "{}"}
        from commands_test import spec
        self.assertEqual("7", runner.validate_resident_spec(spec(env=env))["env"]["SOULSHOUSE_GITHUB_IMPORT_ID"])
        with self.assertRaises(runner.BadCommand):
            runner.validate_resident_spec(spec(env={"TRIGGER_BEARER_TOKEN": "t", "MIRA_ROOT": "/x"}))

    def test_it_runs_through_the_command_path_once(self):
        state = runner.CommandState(self.dir)
        command = {"id": "a" * 32, "kind": "check_runtime_trust", "generation": 1, "payload": payload()}
        self.assertEqual("trusted", runner.execute_command(command, state, self.host)[1]["result"]["trust"])
        runner.execute_command(command, state, self.host)
        self.assertEqual(1, len(self.exit.calls), "a redelivered check is answered from memory")


if __name__ == "__main__":
    unittest.main()

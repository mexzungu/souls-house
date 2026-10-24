module Agents
  # What tells an imported home's runtime what it is, and the check that says
  # whether Chaos trusts it. One source for the house sandbox and for a VM
  # (docs/2026-10-10-vm-imports.md, points 5 and 6), so the two can't drift:
  # Agents::Sandbox turns these into `docker create -e` arguments, and
  # Agents::RemoteRuntime sends the same names and values to the runner, whose
  # allowlist has exactly these names.
  module ImportedHomeEnv

    IDENTITY_PATH = "/home/agent/identity".freeze

    # Verification only. No SQL writes, interactive approvals or project code.
    # A site operator grants trust through Chaos's supported interactive
    # screen. The host runner carries a byte-for-byte copy of this script
    # (RUNTIME_TRUST_CHECK in host-runner/souls_house_runner.py; a test keeps
    # them equal), because Rails sends a VM values, never code.
    RUNTIME_TRUST_CHECK = <<~PYTHON.freeze
      from pathlib import Path
      import sys
      try:
          import github_import_approval
          import imported_home
          import os
          if os.environ.get('SOULSHOUSE_HOME_SYNC_STRATEGY') == 'standard':
              import standard_home_sync
              assert callable(imported_home.standard_sync_configuration)
          entrypoint = Path('/usr/local/bin/entrypoint.sh').read_text()
          assert entrypoint.index('github_import_approval.py') < entrypoint.index('runtime_hooks.py')
          assert entrypoint.index('--runtime-trust-check') < entrypoint.index('home_sync_loop.py')
      except (ImportError, OSError, ValueError, AssertionError):
          print('unsupported-managed-import-runtime')
          sys.exit(79)
      try:
          imported_home.main(['imported_home.py', '--runtime-trust-check'])
      except (ValueError, KeyError, OSError):
          sys.exit(78)
    PYTHON

    module_function

    # The imported home's environment, in the order the house has always
    # passed it. Empty for a house home. A GitHub import must still hold its
    # approval (require_approval! raises otherwise).
    def for(agent)
      return {} unless agent.imported_home?

      env = {
        "SOULSHOUSE_HOME_PROFILE" => agent.home_profile,
        "SOULSHOUSE_PORTABLE_HOME_ID" => agent.portable_home_id,
        agent.imported_home_root_env => IDENTITY_PATH,
        "AGENT_REPO_PATH" => IDENTITY_PATH,
        "TZ" => "Europe/Madrid"
      }
      # Default off. Only the Anthropic-subscription clamp combination reads it.
      env["SOULSHOUSE_IMPORTED_CLAMP_OMIT_FORCED_LOGIN"] = "1" if Agents::Config.imported_clamp_omit_forced_login?
      if (request = agent.github_resident_import)
        request.require_approval!
        env.merge!(
          "SOULSHOUSE_GITHUB_IMPORT_ID" => request.id.to_s,
          "SOULSHOUSE_GITHUB_IMPORT_FINGERPRINT" => request.approved_credential_fingerprint,
          "SOULSHOUSE_GITHUB_IMPORT_REPOSITORY" => request.repository,
          "SOULSHOUSE_GITHUB_IMPORT_BRANCH" => request.branch,
          "SOULSHOUSE_HOME_SYNC_STRATEGY" => request.sync_strategy,
          "SOULSHOUSE_HOME_SYNC_CONFIGURATION" => request.sync_configuration.to_json,
          "SOULSHOUSE_GITHUB_IMPORT_CONNECTION" => request.service_connection.public_id
        )
        env["SOULSHOUSE_GITHUB_IMPORT_REQUIRE_OAUTH_TRUST"] = "1" if oauth_trust_required?(agent)
      end
      env
    end

    # What the trust check runs with, besides the fixed profile and root,
    # which the house and the runner each set themselves.
    def trust_check(agent)
      request = agent.github_resident_import
      {
        "SOULSHOUSE_PORTABLE_HOME_ID" => agent.portable_home_id,
        "SOULSHOUSE_HOME_SYNC_STRATEGY" => request.sync_strategy,
        "SOULSHOUSE_HOME_SYNC_CONFIGURATION" => request.sync_configuration.to_json,
        "SOULSHOUSE_GITHUB_IMPORT_REQUIRE_OAUTH_TRUST" => oauth_trust_required?(agent) ? "1" : "0"
      }
    end

    def oauth_trust_required?(agent)
      provider = Agents::Sandbox.subscription_provider_for(agent)
      provider.in?(%w[openai xai]) && agent.provider_auth_mode(provider) == "oauth_account"
    end

  end
end

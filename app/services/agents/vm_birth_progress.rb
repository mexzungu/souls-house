# The steps of a birth on the resident's own server, for the page a person
# watches while it happens (agents/onboarding). ProvisionVmAgentJob moves
# through them about a minute apart, and the whole birth usually takes about
# five minutes; shown as one "Home prepared" step it looked stuck.
#
# Read only: this never advances, retries or writes anything (VmSeed#status
# writes seeded_at, so the seed is read from its commands here instead).
module Agents
  class VmBirthProgress

    def self.for(agent)
      placement = Agents::RemoteRuntime.placement_for(agent)
      return nil unless placement&.vm_birth? && placement.kind.in?([ nil, "birth" ])

      new(agent, placement).steps
    end

    def initialize(agent, placement)
      @agent = agent
      @placement = placement
    end

    def steps
      ready = @agent.runtime_ready_at.present?
      # The times are what the first births took (October 2026), one sweep
      # a minute apart: a person watching wants to know a spinner is normal.
      [
        step("server_ordered", "Server ordered",
          "#{house} is renting a server of its own from the hosting provider.", "about a minute",
          ready || server_provisioned?),
        step("server_online", "Server online",
          "The server has started and checked in with #{house}.", "about a minute", ready || enrolled?),
        step("home_prepared", "Home prepared",
          "Their home folder, with the beginning in it, is on the server.", "under a minute",
          ready || command_done?("seed_home")),
        step("runtime_started", "Runtime started",
          "Their runtime is running on the server.", "about two minutes", ready || command_done?("start_resident")),
        step("first_backup", "First backup saved",
          "A first copy of their home is saved off the server, so nothing is lost if it fails.", "one to two minutes",
          ready)
      ]
    end

    private

    def house = Setting.instance.site_name

    def step(key, label, detail, estimate, done) = { key:, label:, detail:, estimate:, done: }

    def server_provisioned?
      @placement.cloud_procurement_operations.where(placement_generation: @placement.generation, state: "provisioned").exists?
    end

    def enrolled?
      RunnerEnrollment.where(agent_placement_id: @placement.id, revoked_at: nil).where.not(enrolled_at: nil).exists?
    end

    def command_done?(kind)
      RunnerCommand.where(agent_placement_id: @placement.id, kind:, generation: @placement.generation, state: "done").exists?
    end

  end
end

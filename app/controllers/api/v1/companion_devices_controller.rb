module Api
  module V1
    class CompanionDevicesController < BaseController

      before_action :require_human_actor!

      def update
        account = human_account!
        return head :forbidden unless human_membership!(account).admin?

        device = CompanionDevice.where(account: account).find(params[:id])
        return head :unprocessable_entity unless [ "pause", "resume", "revoke" ].include?(params[:control])

        device.with_lock do
          if params[:control] == "revoke"
            device.revoke!
          else
            device.update!(paused: params[:control] == "pause")
          end
          CompanionOperation.where(companion_device: device, state: CompanionOperation::ACTIVE_STATES)
            .update_all(state: "cancelled", outcome: "changed") unless params[:control] == "resume"
          CompanionChannel.broadcast_to(device, { type: params[:control] == "revoke" ? "revoke" : "pause" }) unless params[:control] == "resume"
          audit_human_action("companion_#{params[:control]}", device, account: account)
        end
        head :no_content
      end

    end
  end
end

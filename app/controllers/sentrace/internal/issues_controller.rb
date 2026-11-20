module Sentrace
  module Internal
    class IssuesController < BaseController
      before_action :require_write_scope!, only: :update

      def index
        payload = local_backend.list_issues(
          project_id: scalar_param(:project_id),
          status: scalar_param(:status),
          level: scalar_param(:level),
          release: scalar_param(:release),
          since: scalar_param(:since),
          until: scalar_param(:until),
          limit: scalar_param(:limit),
          cursor: scalar_param(:cursor)
        )
        render json: payload
      end

      def show
        payload = local_backend.get_issue(
          issue_id: scalar_param(:id),
          project_id: scalar_param(:project_id)
        )
        render json: payload
      end

      def update
        payload = local_backend.update_issue_status(
          issue_id: scalar_param(:id),
          status: scalar_param(:status),
          project_id: scalar_param(:project_id)
        )
        render json: payload
      end

      private
        def require_write_scope!
          if @current_mcp_token&.read_only?
            render json: { error: "Forbidden: read-only token cannot update issue status" }, status: :forbidden
          end
        end
    end
  end
end

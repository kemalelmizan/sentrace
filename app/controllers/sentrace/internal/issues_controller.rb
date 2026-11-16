module Sentrace
  module Internal
    class IssuesController < BaseController
      def index
        payload = local_backend.list_issues(
          project_id: params[:project_id],
          status: params[:status],
          level: params[:level],
          release: params[:release],
          since: params[:since],
          until: params[:until],
          limit: params[:limit],
          cursor: params[:cursor]
        )
        render json: payload
      end

      def show
        payload = local_backend.get_issue(
          issue_id: params[:id],
          project_id: params[:project_id]
        )
        render json: payload
      end

      def update
        payload = local_backend.update_issue_status(
          issue_id: params[:id],
          status: params[:status],
          project_id: params[:project_id]
        )
        render json: payload
      end
    end
  end
end

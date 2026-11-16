module Sentrace
  module Internal
    class EventsController < BaseController
      def index
        payload = local_backend.list_events(
          project_id: params[:project_id],
          issue_id: params[:issue_id],
          since: params[:since],
          until: params[:until],
          limit: params[:limit],
          cursor: params[:cursor]
        )
        render json: payload
      end

      def show
        payload = local_backend.get_event(
          event_id: params[:id],
          project_id: params[:project_id]
        )
        render json: payload
      end
    end
  end
end

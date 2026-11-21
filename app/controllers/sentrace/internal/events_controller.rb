module Sentrace
  module Internal
    class EventsController < BaseController
      def index
        payload = local_backend.list_events(
          project_id: scalar_param(:project_id),
          issue_id: scalar_param(:issue_id),
          platform: scalar_param(:platform),
          request_id: scalar_param(:request_id),
          ingestion_source: scalar_param(:ingestion_source),
          since: scalar_param(:since),
          until: scalar_param(:until),
          limit: scalar_param(:limit),
          cursor: scalar_param(:cursor)
        )
        render json: payload
      end

      def show
        payload = local_backend.get_event(
          event_id: scalar_param(:id),
          project_id: scalar_param(:project_id)
        )
        render json: payload
      end
    end
  end
end

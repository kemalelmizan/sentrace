module Sentrace
  module Internal
    class ProjectsController < BaseController
      before_action :require_admin_scope!, only: %i[create update destroy]

      def index
        scope = Project.includes(:project_keys).order(:id)
        scope = scope.where(id: @current_mcp_token.project_id) if @current_mcp_token&.project_id
        projects = scope.map { |project| serialize_project(project) }
        render json: { projects: projects }
      end

      def show
        project = find_authorized_project!(scalar_param(:id), include_keys: true)
        render json: { project: serialize_project(project) }
      end

      def create
        if @current_mcp_token&.project_id
          return render json: { error: "Forbidden: project-scoped token cannot create projects" }, status: :forbidden
        end

        slug = scalar_param(:slug).to_s.strip
        if slug.empty?
          return render json: { error: "slug is required" }, status: 422
        end

        project, key = Project.provision!(slug: slug, name: scalar_param(:name))
        render json: { project: serialize_project(project, key_override: key) }, status: :created
      end

      def update
        project = find_authorized_project!(scalar_param(:id))
        attrs = {}
        attrs[:name] = scalar_param(:name) if params.key?(:name)
        attrs[:slug] = scalar_param(:slug) if params.key?(:slug)
        project.update!(attrs) if attrs.any?

        render json: { project: serialize_project(project) }
      end

      def destroy
        project = find_authorized_project!(scalar_param(:id))
        project.destroy!
        head :no_content
      end

      private
        def find_authorized_project!(raw_id, include_keys: false)
          if @current_mcp_token&.project_id
            stripped = raw_id.to_s.strip
            unless stripped.match?(/\A[1-9]\d{0,18}\z/) && Integer(stripped, 10) == @current_mcp_token.project_id
              raise McpForbiddenError, "Token is scoped to project #{@current_mcp_token.project_id}"
            end
          end

          scope = include_keys ? Project.includes(:project_keys) : Project.all
          scope.find(raw_id)
        end

        def serialize_project(project, key_override: nil)
          include_creds = can_view_project_credentials?
          active_key = include_creds ? (key_override || project.active_key) : nil
          config = Sentrace.configuration
          configured_public_base = config.public_base_url.to_s.strip
          origin_base =
            if !configured_public_base.empty?
              configured_public_base.chomp("/")
            elsif config.allow_request_base_url_fallback
              request.base_url
            end
          dsn =
            if active_key && origin_base
              base_url = "#{origin_base}#{Sentrace::Engine.routes.find_script_name({})}"
              begin
                Dsn.build(base_url: base_url, public_key: active_key.public_key, project_id: project.id).to_s
              rescue InvalidDsnError
                nil
              end
            end

          {
            id: project.id,
            slug: project.slug,
            name: project.name,
            public_key: active_key&.public_key,
            dsn: dsn,
            created_at: project.created_at.utc.iso8601,
            updated_at: project.updated_at.utc.iso8601
          }
        end
    end
  end
end

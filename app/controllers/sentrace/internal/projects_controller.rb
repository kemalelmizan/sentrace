module Sentrace
  module Internal
    class ProjectsController < BaseController
      before_action :require_admin_scope!, only: %i[create update destroy]

      def index
        projects = Project.includes(:project_keys).order(:id).map { |project| serialize_project(project) }
        render json: { projects: projects }
      end

      def show
        project = Project.includes(:project_keys).find(scalar_param(:id))
        render json: { project: serialize_project(project) }
      end

      def create
        slug = scalar_param(:slug).to_s.strip
        if slug.empty?
          return render json: { error: "slug is required" }, status: 422
        end

        project, key = Project.provision!(slug: slug, name: scalar_param(:name))
        render json: { project: serialize_project(project, key_override: key) }, status: :created
      end

      def update
        project = Project.find(scalar_param(:id))
        attrs = {}
        attrs[:name] = scalar_param(:name) if params.key?(:name)
        attrs[:slug] = scalar_param(:slug) if params.key?(:slug)
        project.update!(attrs) if attrs.any?

        render json: { project: serialize_project(project) }
      end

      def destroy
        project = Project.find(scalar_param(:id))
        project.destroy!
        head :no_content
      end

      private
        def serialize_project(project, key_override: nil)
          include_creds = can_view_project_credentials?
          active_key = include_creds ? (key_override || project.active_key) : nil
          configured_public_base = Sentrace.configuration.public_base_url.to_s.strip
          origin_base = configured_public_base.empty? ? request.base_url : configured_public_base.chomp("/")
          base_url = "#{origin_base}#{Sentrace::Engine.routes.find_script_name({})}"
          dsn =
            if active_key
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

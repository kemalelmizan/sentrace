module Sentrace
  module Internal
    class ProjectsController < BaseController
      def index
        projects = Project.includes(:project_keys).order(:id).map { |project| serialize_project(project) }
        render json: { projects: projects }
      end

      def show
        project = Project.includes(:project_keys).find(params[:id])
        render json: { project: serialize_project(project) }
      end

      def create
        slug = params[:slug].to_s.strip
        if slug.empty?
          return render json: { error: "slug is required" }, status: :unprocessable_content
        end

        project, key = Project.provision!(slug: slug, name: params[:name])
        render json: { project: serialize_project(project, key_override: key) }, status: :created
      end

      def update
        project = Project.find(params[:id])
        attrs = {}
        attrs[:name] = params[:name] if params.key?(:name)
        attrs[:slug] = params[:slug] if params.key?(:slug)
        project.update!(attrs) if attrs.any?

        render json: { project: serialize_project(project) }
      end

      def destroy
        project = Project.find(params[:id])
        project.destroy!
        head :no_content
      end

      private
        def serialize_project(project, key_override: nil)
          active_key = key_override || project.active_key
          base_url = "#{request.base_url}#{Sentrace::Engine.routes.find_script_name({})}"
          dsn = active_key ? Dsn.build(base_url: base_url, public_key: active_key.public_key, project_id: project.id).to_s : nil

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

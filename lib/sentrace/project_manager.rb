module Sentrace
  class ProjectManager
    DEFAULT_BASE_URL = "http://localhost:3000/sentrace"

    class ProjectNotFoundError < Error; end

    def initialize(io: $stdout, base_url: ENV.fetch("SENTRACE_BASE_URL", DEFAULT_BASE_URL))
      @io = io
      @base_url = base_url
    end

    def list
      projects = Project.includes(:project_keys).order(:id).to_a
      if projects.empty?
        @io.puts "No Sentrace projects registered."
        return projects
      end

      @io.puts format("%-6s %-24s %-28s %s", "ID", "SLUG", "NAME", "ACTIVE PUBLIC KEY")
      projects.each do |project|
        active_pub = project.active_key&.public_key || "(none)"
        safe_name = RequestSecurity.sanitize_single_line(project.name, max_chars: 120)
        @io.puts format("%-6s %-24s %-28s %s", project.id, project.slug, safe_name, active_pub)
      end
      projects
    end

    def create(slug:, name: nil)
      if slug.nil? || slug.to_s.strip.empty?
        raise ArgumentError, "Project slug is required (usage: bin/rails \"sentrace:projects:create[my-app]\")"
      end

      project, key = Project.provision!(slug: slug, name: name)
      dsn = Dsn.build(base_url: @base_url, public_key: key.public_key, project_id: project.id)

      @io.puts "Created Sentrace project:"
      @io.puts "  ID:         #{project.id}"
      @io.puts "  Slug:       #{project.slug}"
      @io.puts "  Name:       #{project.name}"
      @io.puts "  Public Key: #{key.public_key}"
      @io.puts "  DSN:        #{dsn}"
      project
    end

    def rotate_key(slug:)
      normalized_slug = slug.to_s.strip.downcase
      if normalized_slug.empty?
        raise ArgumentError, "Project slug is required (usage: bin/rails \"sentrace:projects:rotate_key[my-app]\")"
      end

      project = Project.find_by(slug: normalized_slug)
      unless project
        raise ProjectNotFoundError, "Sentrace project '#{normalized_slug}' not found."
      end

      new_key = project.rotate_key!
      dsn = Dsn.build(base_url: @base_url, public_key: new_key.public_key, project_id: project.id)

      @io.puts "Rotated DSN key for '#{project.slug}' (id=#{project.id}):"
      @io.puts "  Public Key: #{new_key.public_key}"
      @io.puts "  DSN:        #{dsn}"
      new_key
    end
  end
end

require "rails_helper"

RSpec.describe "Transaction Isolation, Bounded Async Queue, and Fork Safety" do
  self.use_transactional_tests = false

  let!(:project) { Sentrace::Project.ensure!(slug: "tx-fork-app", name: "TX Fork App").first }

  before do
    Sentrace.clear_scope!
    Sentrace::AsyncWorker.reset_default!
  end

  after do
    Sentrace::AsyncWorker.default.resume_processing!
    Sentrace::AsyncWorker.reset_default!
    Sentrace.clear_scope!
    Sentrace.reset_configuration!
    Sentrace::Event.delete_all
    Sentrace::Issue.delete_all
    Sentrace::ProjectKey.delete_all
    Sentrace::Project.delete_all
  end

  %i[async inline].each do |dispatch_mode|
    describe "under capture_dispatch = #{dispatch_mode.inspect}" do
      before do
        Sentrace.configure do |config|
          config.project_slug = project.slug
          config.capture_dispatch = dispatch_mode
        end
      end

      it "persists captured exceptions even when ActiveRecord::Base.transaction rolls back" do
        captured_event_id = nil

        expect {
          ActiveRecord::Base.transaction do
            Sentrace::Project.create!(name: "Rolled Back Project", slug: "rolled-back-slug")
            begin
              raise RuntimeError, "payment settlement failed inside transaction"
            rescue RuntimeError => e
              captured_event_id = Sentrace.capture_exception(e, tags: { mode: dispatch_mode.to_s })
              raise
            end
          end
        }.to raise_error(RuntimeError, /payment settlement failed/)

        expect(Sentrace.flush(timeout: 3.0)).to be(true)
        expect(captured_event_id).to match(/\A[0-9a-f]{32}\z/)

        # Business write rolled back:
        expect(Sentrace::Project.exists?(slug: "rolled-back-slug")).to be(false)

        # Error capture survived rollback on an isolated pooled connection:
        persisted = Sentrace::Event.find_by(project_id: project.id, event_id: captured_event_id)
        expect(persisted).to be_present
        expect(persisted.event_data.dig("tags", "mode")).to eq(dispatch_mode.to_s)
      end

      it "persists captured exceptions when caller connection is aborted in PG::InFailedSqlTransaction" do
        captured_event_id = nil

        expect {
          ActiveRecord::Base.transaction do
            begin
              ActiveRecord::Base.connection.execute("SELECT * FROM sentrace_nonexistent_table_for_aborted_tx_spec")
            rescue ActiveRecord::StatementInvalid => e
              raw_status = ActiveRecord::Base.connection.raw_connection.transaction_status
              expect(raw_status).to eq(PG::PQTRANS_INERROR)

              captured_event_id = Sentrace.capture_exception(e, tags: { pg_aborted: "true" })
              raise
            end
          end
        }.to raise_error(ActiveRecord::StatementInvalid)

        expect(Sentrace.flush(timeout: 3.0)).to be(true)
        expect(captured_event_id).to match(/\A[0-9a-f]{32}\z/)

        persisted = Sentrace::Event.find_by(project_id: project.id, event_id: captured_event_id)
        expect(persisted).to be_present
        expect(persisted.event_data.dig("tags", "pg_aborted")).to eq("true")
      end
    end
  end

  describe "bounded SizedQueue overflow backpressure" do
    it "drops excess events without blocking caller threads and logs a warning when async_queue_size is full" do
      warnings = []
      allow(Rails.logger).to receive(:warn) { |msg| warnings << msg.to_s }

      Sentrace.configure do |config|
        config.project_slug = project.slug
        config.capture_dispatch = :async
        config.async_queue_size = 2
      end

      worker = Sentrace::AsyncWorker.default
      worker.pause_processing!

      # First item may be popped into the paused wait loop; enqueue enough items to exceed capacity (2) + 1 in-flight
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      returned_ids = 6.times.map { |i| Sentrace.capture_message("burst-#{i}") }
      elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000.0

      expect(elapsed_ms).to be < 500.0
      accepted = returned_ids.compact
      dropped_count = returned_ids.count(&:nil?)

      expect(accepted.size).to be_between(2, 3)
      expect(dropped_count).to be >= 3
      expect(warnings.any? { |w| w.include?("async_queue_size (2) is full") }).to be(true)

      worker.resume_processing!
      expect(Sentrace.flush(timeout: 3.0)).to be(true)

      accepted.each do |eid|
        expect(Sentrace::Event.exists?(project_id: project.id, event_id: eid)).to be(true)
      end
    end
  end

  describe "Puma preload_app! Process.fork safety", if: Process.respond_to?(:fork) do
    it "automatically respawns a fresh worker thread in forked child processes when Process.pid changes" do
      Sentrace.configure do |config|
        config.project_slug = project.slug
        config.capture_dispatch = :async
      end

      parent_event_id = Sentrace.capture_message("parent-before-fork")
      expect(Sentrace.flush(timeout: 3.0)).to be(true)
      expect(Sentrace::AsyncWorker.default.worker_pid).to eq(Process.pid)

      read_io, write_io = IO.pipe

      child_pid = Process.fork do
        read_io.close
        child_id = Sentrace.capture_message("child-after-fork", tags: { worker_pid: Process.pid.to_s })
        flushed = Sentrace.flush(timeout: 3.0)
        write_io.write("#{child_id}:#{flushed}")
        write_io.close
        Process.exit!(0)
      end

      write_io.close
      payload = read_io.read
      read_io.close
      _, status = Process.waitpid2(child_pid)

      expect(status.exitstatus).to eq(0)
      child_event_id, flushed_flag = payload.split(":", 2)
      expect(flushed_flag).to eq("true")
      expect(child_event_id).to match(/\A[0-9a-f]{32}\z/)

      expect(Sentrace::Event.exists?(project_id: project.id, event_id: parent_event_id)).to be(true)
      child_event = Sentrace::Event.find_by(project_id: project.id, event_id: child_event_id)
      expect(child_event).to be_present
      expect(child_event.event_data.dig("tags", "worker_pid")).to eq(child_pid.to_s)
    end
  end
end

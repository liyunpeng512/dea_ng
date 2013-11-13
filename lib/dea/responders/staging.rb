require "dea/staging/staging_task"

require "dea/loggregator"

module Dea::Responders
  class Staging
    attr_reader :nats
    attr_reader :dea_id
    attr_reader :bootstrap
    attr_reader :staging_task_registry
    attr_reader :dir_server
    attr_reader :resource_manager
    attr_reader :config

    def initialize(nats, dea_id, bootstrap, staging_task_registry, dir_server, resource_manager, config)
      @nats = nats
      @dea_id = dea_id
      @bootstrap = bootstrap
      @staging_task_registry = staging_task_registry
      @resource_manager = resource_manager
      @dir_server = dir_server
      @config = config
    end

    def start
      return unless configured_to_stage?
      subscribe_to_staging
      subscribe_to_dea_specific_staging
      subscribe_to_staging_stop
    end

    def stop
      unsubscribe_from_staging
      unsubscribe_from_dea_specific_staging
      unsubscribe_from_staging_stop
    end

    def handle(response)
      message = StagingMessage.new(response.data)
      app_id = message.app_id
      logger = logger_for_app(app_id)

      Dea::Loggregator.emit(app_id, "Got staging request for app with id #{app_id}")
      logger.info("staging.handle.start", request: message)

      task = Dea::StagingTask.new(bootstrap, dir_server, message, buildpacks_in_use, logger)
      unless resource_manager.could_reserve?(task.memory_limit_mb, task.disk_limit_mb)
        constrained_resource = resource_manager.get_constrained_resource(task.memory_limit_mb, task.disk_limit_mb)
        respond_to_response(response, {
          :task_id => task.task_id,
          :error => "Not enough #{constrained_resource} resources available"
        })
        logger.error "staging.start.insufficient-resource",
                     :app => app_id,
                     :constrained_resource => constrained_resource
        return
      end

      staging_task_registry.register(task)

      bootstrap.save_snapshot

      notify_setup_completion(response, task)
      notify_completion(message, task)
      notify_upload(response, task)
      notify_stop(response, task)

      task.start
    rescue => e
      logger.error "staging.handle.failed", error: e, backtrace: e.backtrace
    end

    def handle_stop(message)
      staging_task_registry.each do |task|
        if message.data["app_id"] == task.staging_message.app_id
          task.stop
        end
      end
    rescue => e
      logger.error "staging.handle_stop.failed", :error => e, :backtrace => e.backtrace
    end

    private

    def configured_to_stage?
      config["staging"] && config["staging"]["enabled"]
    end

    def subscribe_to_staging # Can we delete this??
      options = {:do_not_track_subscription => true, :queue => "staging"}
      @staging_sid = nats.subscribe("staging", options) { |response| handle(response) }
    end

    def unsubscribe_from_staging
      nats.unsubscribe(@staging_sid) if @staging_sid
    end

    def subscribe_to_dea_specific_staging
      options = {:do_not_track_subscription => true}
      @dea_specified_staging_sid = nats.subscribe("staging.#{@dea_id}.start", options) { |response| handle(response) }
    end

    def unsubscribe_from_dea_specific_staging
      nats.unsubscribe(@dea_specified_staging_sid) if @dea_specified_staging_sid
    end

    def subscribe_to_staging_stop
      options = {:do_not_track_subscription => true}
      @staging_stop_sid = nats.subscribe("staging.stop", options) { |response| handle_stop(response) }
    end

    def unsubscribe_from_staging_stop
      nats.unsubscribe(@staging_stop_sid) if @staging_stop_sid
    end

    def notify_setup_completion(response, task)
      task.after_setup_callback do |error|
        respond_to_response(response, {
          :task_id => task.task_id,
          :streaming_log_url => task.streaming_log_url,
          :error => (error.to_s if error)
        })
      end
    end

    def notify_completion(message, task)
      task.after_complete_callback do |error|
        if message.start_message && !error
          start_message = message.start_message.to_hash
          start_message["sha1"] = task.droplet_sha1
          bootstrap.start_app(start_message)
        end
      end
    end

    def notify_upload(response, task)
      task.after_upload_callback do |error|
        respond_to_response(response, {
          :task_id => task.task_id,
          :error => (error.to_s if error),
          :detected_buildpack => task.detected_buildpack,
          :droplet_sha1 => task.droplet_sha1
        })

        staging_task_registry.unregister(task)

        bootstrap.save_snapshot
      end
    end

    def notify_stop(response, task)
      task.after_stop_callback do |error|
        respond_to_response(response, {
          :task_id => task.task_id,
          :error => (error.to_s if error),
        })

        staging_task_registry.unregister(task)

        bootstrap.save_snapshot
      end
    end

    def respond_to_response(response, params)
      response.respond(
        "task_id" => params[:task_id],
        "task_streaming_log_url" => params[:streaming_log_url],
        "detected_buildpack" => params[:detected_buildpack],
        "error" => params[:error],
        "droplet_sha1" => params[:droplet_sha1]
      )
    end

    def logger_for_app(app_id)
      logger = Steno::Logger.new("Staging", Steno.config.sinks, :level => Steno.config.default_log_level)
      logger.tag(:app_guid => app_id)
    end

    def buildpacks_in_use
      staging_task_registry.flat_map do |task|
        task.staging_message.admin_buildpacks
      end.uniq
    end
  end
end

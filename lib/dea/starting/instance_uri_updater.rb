module Dea
  class InstanceUriUpdater
    def initialize(instance, uris)
      @instance = instance
      @uris = uris
    end

    def update(router_client)
      current_uris = @instance.application_uris

      logger.debug("Mapping new URIs")
      logger.debug("New: #{@uris} \n Old: #{current_uris}")

      new_uris = @uris - current_uris
      unless new_uris.empty?
        router_client.register_instance(@instance, :uris => new_uris)
      end

      obsolete_uris = current_uris - @uris
      unless obsolete_uris.empty?
        router_client.unregister_instance(@instance, :uris => obsolete_uris)
      end

      @instance.application_uris = @uris
    end
  end
end

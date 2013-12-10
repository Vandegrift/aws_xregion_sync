class AwsXRegionSync
  class SyncResult

    attr_reader :name, :completed, :created_resource, :errors

    def initialize name, completed, created_resource, errors = []
      @name = name
      @completed = completed
      @created_resource = created_resource
      @errors = errors ? errors : []
    end


    def failed?
      !completed
    end

    def sync_required?
      completed && created_resource == true
    end
  end
end
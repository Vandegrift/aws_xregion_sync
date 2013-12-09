require 'yaml'

class AwsXRegionSync
  class Configure

    def self.configure_from_file file_path
      # For now, just assume a yaml config file..we can certainly support json/xml or something more complicated here internally later.
      generate_sync_jobs load_yaml_config_file file_path
    end

    def self.generate_sync_jobs config
      # We need at least one sync key, each sync must have a type indicator, each sync must have a source and destination region
      sync_keys = config.keys
      
      global_aws_config = config['aws_client_config']
      sync_jobs = []
      configuration_errors = {}
      sync_keys.each do |job_key|
        if job_key.upcase.to_s.start_with? "SYNC_"
          sync_config = config[job_key]
          begin
            sync_jobs << create_sync_job(global_aws_config, job_key, sync_config)
          rescue => e
            configuration_errors[job_key] = [e]
          end
        end
      end

      {jobs: sync_jobs, errors: configuration_errors}
    end

    def self.create_sync_job global_aws_config, job_key, job_config
      # merge the global and local aws client config settings together, allowing for easy global and per sync config settings 
      if global_aws_config
        if job_config['aws_client_config']
          job_config['aws_client_config'] = global_aws_config.merge job_config['aws_client_config']
        else
          # Just want to make a new hash object here
          job_config['aws_client_config'] = global_aws_config.merge({})
        end
      end

      sync_job = nil
      case job_config['sync_type']
      when 'ec2_ami'
        sync_job = Ec2AmiSync
      when 'rds_automated_snapshot'
        sync_job = RdsAutomatedSnapshotSync
      else
        raise AwsXRegionSyncConfigError, "The #{job_key} configuration 'sync_type' value '#{job_config['sync_type']}' is not a supported AWS Sync type."
      end

      job = sync_job.new job_key, job_config
      job.validate_config
      job
    end

    def self.load_yaml_config_file config
      if config.is_a? String
        YAML.load_file config
      else
        YAML.load config
       end
    end
    private_class_method :load_yaml_config_file

  end
end
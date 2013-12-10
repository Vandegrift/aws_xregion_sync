require 'aws-sdk'
require 'require_all'
require_rel 'aws_xregion_sync'

class AwsXRegionSync

  def self.run config_file_path_or_hash
    do_syncs config_file_path_or_hash, :sync
  end

  def self.sync_required? config_file_path_or_hash
    do_syncs config_file_path_or_hash, :sync_required?
  end

  def self.do_syncs config_file_path_or_hash, job_method
    job_configs = configure config_file_path_or_hash
    error_results = create_results_from_config_errors job_configs[:errors]
    job_syncs = sync job_configs[:jobs], job_method

    job_syncs + error_results
  end
  private_class_method :do_syncs

  def self.configure config
    # Use to_hash since this will allow a broader range of config options to anyone
    # passing in a config object rather than a filename
    if config.respond_to? :to_hash
      Configure.generate_sync_jobs config.to_hash
    else
      Configure.configure_from_file config 
    end
  end
  private_class_method :configure

  def self.sync jobs, job_method
    results = []
    jobs.each do |job|
      completed = false
      errors = nil
      synced_object_id = nil
      begin
        synced_object_id = job.send job_method
        completed = true
      rescue Exception => e
        # Yes, we're trapping everything here.  I'd like all the sync jobs to at least attempt
        # to run each time sync is called.  If they all bail with something like a memory error
        # or something else along those lines, then so be it, the error will get raised eventually
        errors = [e]
      end

      results << SyncResult.new(job.sync_name, completed, synced_object_id, errors)
    end

    results
  end
  private_class_method :sync

  def self.create_results_from_config_errors errors
    errors ? errors.map {|job_key, config_errors| SyncResult.new(job_key, false, nil, config_errors)} : []
  end
  private_class_method :create_results_from_config_errors
end
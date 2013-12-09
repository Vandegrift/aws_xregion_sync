class AwsXRegionSync
  class RdsAutomatedSnapshotSync < AwsSync

    def validate_config
      raise AwsXRegionSyncConfigError, "The #{self.sync_name} configuration must provide a 'db_instance' option to use to locate automated snapshots." unless config['db_instance'] && config['db_instance'].length > 0
      # This call will raise if there's an invalid value..so just call it right now
      max_snapshots
      super
    end

    def sync
      # There doesn't appear to be a direct way of actually obtaining
      # a region reference after initializing the rds client - like there is for the s3 client
      # so we'll just create multiple clients.
      source_rds = rds_client config['source_region'], config['db_instance']
      destination_rds = rds_client config['destination_region'], config['db_instance']

      instance = source_rds.db_instances[config['db_instance']]
      raise AwsXRegionSyncConfigError, "No DB Instance with identifier '#{config['db_instance']}' is available for these credentials in region #{config['db_instance']}." unless instance

      # Find all the snapshots
      snapshots = instance.snapshots.with_type('automated').to_a
      raise AwsXRegionSyncConfigError, "No automated snapshots for db '#{config['db_instance']}' are available for these credentials in region #{config['source_region']}." unless snapshots.size > 0

      # Use the created_at attribute of the snapshot to find the newest one
      newest_snapshot = extract_newest_snapshot snapshots
      
      sync_snapshot_to_region source_rds, destination_rds, newest_snapshot
    end

    def sync_snapshot_to_region source_region, destination_region, source_snapshot
      # The way automated snapshot copying seems to work is as long as you're copying snapshot from the same db instance between regions
      # every snapshot you copy from the source region after the first one is simply just an incremental copy.  Because of this we
      # should copy the latest snapshot

      # This first thing we should do is look for a sync tag in the destination snapshot (if present) and see we've already synced this
      # snapshot-id (or if the id is outdated)
      aws_account_id = discover_aws_account_id
      destination_snapshots = retrieve_destination_snapshots_for_instance destination_region, region(source_region), source_snapshot.db_instance.id, aws_account_id

      if destination_snapshots.size == 0 || snapshot_needs_copying(destination_snapshots, source_snapshot)
        sr = region(source_region)
        result = destination_region.client.copy_db_snapshot source_db_snapshot_identifier: arn(sr, aws_account_id, source_snapshot.id), target_db_snapshot_identifier: sanitize_snapshot_id(source_snapshot.id)

        if result[:db_snapshot_identifier]
          destination_snapshot_id = result[:db_snapshot_identifier]

          # Move the source snapshot's created timestamp and id to the destination snapshot's sync tag so that we know the last time
          # the snapshot was synced and what region it was synced from.  Also, log the sync against the source too so we have tangible evidence
          # that it was synced just by looking at it as well.
          dr = region(destination_region)
          
          dest_sync_tag = create_sync_tag sr, source_snapshot.id, timestamp: source_snapshot.created_at, sync_subtype: "From"
          source_sync_tag = create_sync_tag dr, destination_snapshot_id, timestamp: source_snapshot.created_at

          destination_region.client.add_tags_to_resource resource_name: arn(dr, aws_account_id, result[:db_snapshot_identifier]), tags: [dest_sync_tag]
          source_region.client.add_tags_to_resource resource_name: arn(sr, aws_account_id, source_snapshot.id), tags: [source_sync_tag]

          # We'll now clean up older snapshots if necessary
          cleanup_old_snapshots destination_snapshots, max_snapshots, destination_region
        end
      end

      destination_snapshot_id
    end

    private

      def rds_client region, db_instance
        # There doesn't appear to be a direct way of actually obtaining
        # a region reference after initializing an rds client object (unlike w/ the EC2 API)
        rds = make_rds aws_config.merge({region: region})
        # Just force an API call to validate the region setting.  Use the db instance call which we'll use later and, I believe, is cached
        # so there should be no penalty for calling it here (since we use it pretty much directly after this call anyway)
        rds.db_instances[db_instance]
        rds
      rescue
        raise AwsXRegionSyncConfigError, "Region '#{region}' is invalid.  It either does not exist or the given credentials cannot access it."
      end

      def make_rds config
        # purely for mocking
        AWS::RDS.new config
      end

      def extract_newest_snapshot snapshots
        # Grab the snapshot created at time for snapshot as the hash key, then we can sort on the keys and extract the last one from that sorted array
        snapshot_values = {}
        snapshots.each {|s| snapshot_values[s.created_at] = s}
        snapshot_values[snapshot_values.keys.sort[-1]]
      end

      def arn region, account_number, snapshot_id
        # Strip all non-decimal characters from account numbers
        account_number = account_number.gsub(/\D/, "")
        "arn:aws:rds:#{region}:#{account_number}:snapshot:#{snapshot_id}"
      end

      def region client
        client.config.region
      end

      def snapshot_needs_copying destination_snapshots, source_snapshot
        # The snapshot array is already sorted, so the last value from the array is the newest one
        newest_snapshot_hash = destination_snapshots.last
        source_snapshot.created_at.to_i > newest_snapshot_hash[:sync_timestamp].to_i
      end

      def tags_for_snapshot rds, account_number, snapshot_id
        region_client = rds.client
        region_name = region(region_client)

        aws_resource = arn(region_name, account_number, snapshot_id)
        result = region_client.list_tags_for_resource resource_name: arn(region_name, account_number, snapshot_id)
        result[:tag_list]
      end

      def retrieve_destination_snapshots_for_instance destination_region, source_region_name, db_instance, account_number
        snapshots = destination_region.db_instances[db_instance].snapshots.with_type('manual').to_a

        # order them newest to oldest based on their sync tags
        snapshot_list = []
        snapshots.each do |s|
          tags = tags_for_snapshot(destination_region, account_number, s.id)

          sync_tag = find_sync_tag tags, source_region_name, db_instance
          # Ignore any snapshot that doesn't have a sync tag, these are likely actual user initiated manual copies and we don't want to mess with them
          next unless sync_tag

          split_sync_value = parse_sync_tag_value(sync_tag[:value]) if sync_tag
          snapshot_list << {snapshot: s, tags: tags, :sync_timestamp => split_sync_value[:timestamp], :sync_tag=>sync_tag}
        end

        snapshot_list.sort_by {|snapshot| snapshot[:sync_timestamp]}
      end

      def make_to_snapshot_sync_tag_key source_region
        create_sync_tag(source_region, nil, sync_subtype: "From")[:key]
      end

      def find_sync_tag tags, source_region_name, db_instance
        sync_key = make_to_snapshot_sync_tag_key source_region_name

        tags.each do |t|
          return t if t[:key] == sync_key
        end

        nil
      end

      def sanitize_snapshot_id id
        # The official "rules" for identifiers are: 
        # Identifiers must begin with a letter; must contain only ASCII letters, digits, and hyphens;"
        # and must not end with a hyphen or contain two consecutive hyphens
        # Ids for automated snapshots appear to look like "rds:db_instance-YYYY-mm-dd-HH-MM"..that hyphen is invalid
        # For now, just translate any : to -
        id.gsub(":", "-")
      end

      def cleanup_old_snapshots destination_snapshots, max_snapshots_to_retain, destination_region
        if destination_snapshots.size > max_snapshots_to_retain
          # Grab the first max_snapshots # of destination_snapshots (since they're sorted already in ascending order) and just delete them
          snapshots_to_delete = destination_snapshots.take(destination_snapshots.size - max_snapshots_to_retain)

          snapshots_to_delete.each do |snapshot|
            destination_region.client.delete_db_snapshot db_snapshot_identifier: snapshot[:snapshot].id
          end
        end
      end

      def max_snapshots
        retain = nil
        if config['max_snapshots_to_retain']
          retain = Integer(config['max_snapshots_to_retain']) 
        else
          retain = 2
        end

        retain
      rescue 
        raise AwsXRegionSyncConfigError, "The #{self.sync_name} configuration must provide a valid 'max_snapshots_to_retain' option. '#{config['max_snapshots_to_retain']}' is not valid."
      end
  end
end
require 'aws_xregion_sync'
require 'ostruct'

describe AwsXRegionSync::RdsAutomatedSnapshotSync do

  before :each do 
    valid_config = {
      'source_region'=>'source', 'destination_region'=>'destination', 'db_instance' => 'instance'
    }
    @sync = AwsXRegionSync::RdsAutomatedSnapshotSync.new('name', valid_config)
  end

  describe "#validate_config" do

    it 'accepts a valid configuration' do
      expect{@sync.validate_config}.not_to raise_error
    end

    it "verifies a 'db_instance' config value is present" do
      @sync.config.delete 'db_instance'
      expect{@sync.validate_config}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "The name configuration must provide a 'db_instance' option to use to locate automated snapshots."
    end

    it "verifies an integer value was set in the 'max_snapshots_to_retain' config value" do 
      @sync.config['max_snapshots_to_retain'] = "not a number"
      expect{@sync.validate_config}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "The name configuration must provide a valid 'max_snapshots_to_retain' option. 'not a number' is not valid."
    end

    it "verifies a 'source_region' config value is present" do 
      @sync.config.delete 'source_region'
      expect{@sync.validate_config}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "The name configuration must have a valid 'source_region' value."
    end

    it "verifies a 'destination_region' config value is present" do 
      @sync.config.delete 'destination_region'
      expect{@sync.validate_config}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "The name configuration must have a valid 'destination_region' value."
    end
  end


  # There's a lot of mocking happening here to take AWS interaction out of the picture
  # I'm aware that's a potential issue.
  # Ideally we'd use somethign like VCR to reply the actual web requests, but I don't
  # have the patience or time to plug that in right now.

  describe "#sync" do

    it "syncs the latest source database snapshot to the destination region, automatically obtaining aws account id, cleaning up old snapshots" do
      # Don't retain any old snapshots (this tests the cleanup)
      @sync.config["max_snapshots_to_retain"] = 0

      source_region = double("AWS::RDS.source")
      dest_region = double("AWS::RDS.dest")
      source_db = double("AWS::RDS::DBInstance")
      source_db_instances = {'instance'=>source_db}
      @sync.should_receive(:rds_client).with(@sync.config['source_region'], @sync.config['db_instance']).and_return source_region
      source_region.stub(:db_instances).and_return source_db_instances
      source_region.stub(:client).and_return source_region
      source_region.stub(:config).and_return source_region
      source_region.stub(:region).and_return @sync.config['source_region']

      @sync.should_receive(:rds_client).with(@sync.config['destination_region'], @sync.config['db_instance']).and_return dest_region
      dest_region.stub(:db_instances).and_return {}
      dest_region.stub(:client).and_return dest_region
      dest_region.stub(:config).and_return dest_region
      dest_region.stub(:region).and_return @sync.config['destination_region']

      acct_number = '123456'
      @sync.should_receive(:retrieve_aws_account_id).and_return acct_number

      source_db.should_receive(:snapshots).and_return source_db
      source_db.should_receive(:with_type).with("automated").and_return source_db
      source_db.stub(:id).and_return @sync.config['db_instance']
      #Make the snapshot name start w/ RDS: as that's what the actual ones start like, so we're having to change rds:blah to rds-blah when copying the snapshot
      newest_snapshot = OpenStruct.new(:id=>'rds:source_id_2', :created_at=>(Time.now + 60), :db_instance => source_db)
      snapshots = [OpenStruct.new(:id=>'source_id_1', :created_at=>Time.now), newest_snapshot]
      source_db.should_receive(:to_a).and_return snapshots

      dest_snapshot = OpenStruct.new(:id=>'dest_id_2', :created_at=>(Time.now + 60))
      dest_instance = double("Dest DB Instance")
      dest_instance.should_receive(:snapshots).and_return dest_instance
      dest_instance.should_receive(:with_type).with("manual").and_return dest_instance
      dest_instance.should_receive(:to_a).and_return [dest_snapshot]

      dest_region.should_receive(:db_instances).and_return({@sync.config['db_instance']=>dest_instance})
      dest_region.should_receive(:list_tags_for_resource).with(resource_name: "arn:aws:rds:#{@sync.config['destination_region']}:#{acct_number}:snapshot:#{dest_snapshot.id}").and_return({:tag_list=>[{:key=>"Sync-From-#{@sync.config['source_region']}", :value=>"20130101000000+0000 / Origin Snapshot Id"}]})

      actual_dest_snapshot_id = 'copied_id'
      source_snapshot_arn = "arn:aws:rds:#{@sync.config['source_region']}:#{acct_number}:snapshot:#{newest_snapshot.id}"
      dest_region.should_receive(:copy_db_snapshot).with({:source_db_snapshot_identifier => source_snapshot_arn, :target_db_snapshot_identifier => newest_snapshot.id.gsub(":", "-")}).and_return({:db_snapshot_identifier=>actual_dest_snapshot_id})

      dest_tag = @sync.create_sync_tag @sync.config['source_region'], newest_snapshot.id, timestamp: newest_snapshot.created_at, sync_subtype: "From"
      source_tag = @sync.create_sync_tag @sync.config['destination_region'], actual_dest_snapshot_id, timestamp: newest_snapshot.created_at

      dest_region.should_receive(:add_tags_to_resource).with(resource_name: "arn:aws:rds:#{@sync.config['destination_region']}:#{acct_number}:snapshot:#{actual_dest_snapshot_id}", :tags=>[dest_tag])
      source_region.should_receive(:add_tags_to_resource).with(resource_name: source_snapshot_arn, :tags=>[source_tag])

      dest_region.should_receive(:delete_db_snapshot).with :db_snapshot_identifier=>dest_snapshot.id

      expect(@sync.sync).to eq actual_dest_snapshot_id
    end

    it "syncs the latest source database snapshot to the destination region, using config aws_account_id, and not remove any snapshots using default value" do
      @sync.config['aws_client_config'] = {'aws_account_id' => '1234-5678-9101'}

      source_region = double("AWS::RDS.source")
      dest_region = double("AWS::RDS.dest")
      source_db = double("AWS::RDS::DBInstance")
      source_db.stub(:id).and_return @sync.config['db_instance']
      source_db_instances = {'instance'=>source_db}
      @sync.should_receive(:rds_client).with(@sync.config['source_region'], @sync.config['db_instance']).and_return source_region
      source_region.stub(:db_instances).and_return source_db_instances
      source_region.stub(:client).and_return source_region
      source_region.stub(:config).and_return source_region
      source_region.stub(:region).and_return @sync.config['source_region']

      @sync.should_receive(:rds_client).with(@sync.config['destination_region'], @sync.config['db_instance']).and_return dest_region
      dest_region.stub(:db_instances).and_return {}
      dest_region.stub(:client).and_return dest_region
      dest_region.stub(:config).and_return dest_region
      dest_region.stub(:region).and_return @sync.config['destination_region']

      source_db.should_receive(:snapshots).and_return source_db
      source_db.should_receive(:with_type).with("automated").and_return source_db
      newest_snapshot = OpenStruct.new(:id=>'source_id_2', :created_at=>(Time.now + 60), :db_instance=>source_db)
      snapshots = [OpenStruct.new(:id=>'source_id_1', :created_at=>Time.now), newest_snapshot]
      source_db.should_receive(:to_a).and_return snapshots

      dest_snapshot = OpenStruct.new(:id=>'dest_id_2', :created_at=>(Time.now + 60))
      dest_instance = double("Dest DB Instance")
      dest_instance.should_receive(:snapshots).and_return dest_instance
      dest_instance.should_receive(:with_type).with("manual").and_return dest_instance
      dest_instance.should_receive(:to_a).and_return [dest_snapshot]

      dest_region.should_receive(:db_instances).and_return({@sync.config['db_instance']=>dest_instance})
      dest_region.should_receive(:list_tags_for_resource).with(resource_name: "arn:aws:rds:#{@sync.config['destination_region']}:123456789101:snapshot:#{dest_snapshot.id}").and_return({:tag_list=>[{:key=>"Sync-From-#{@sync.config['source_region']}", :value=>"20130101000000+0000 / Origin Snapshot Id"}]})

      actual_dest_snapshot_id = 'copied_id'
      source_snapshot_arn = "arn:aws:rds:#{@sync.config['source_region']}:123456789101:snapshot:#{newest_snapshot.id}"
      dest_region.should_receive(:copy_db_snapshot).with({:source_db_snapshot_identifier => source_snapshot_arn, :target_db_snapshot_identifier => newest_snapshot.id}).and_return({:db_snapshot_identifier=>actual_dest_snapshot_id})  

      dest_tag = @sync.create_sync_tag @sync.config['source_region'], newest_snapshot.id, timestamp: newest_snapshot.created_at, sync_subtype: "From"
      source_tag = @sync.create_sync_tag @sync.config['destination_region'], actual_dest_snapshot_id, timestamp: newest_snapshot.created_at

      dest_region.should_receive(:add_tags_to_resource).with(resource_name: "arn:aws:rds:#{@sync.config['destination_region']}:123456789101:snapshot:#{actual_dest_snapshot_id}", :tags=>[dest_tag])
      source_region.should_receive(:add_tags_to_resource).with(resource_name: source_snapshot_arn, :tags=>[source_tag])

      expect(@sync.sync).to eq actual_dest_snapshot_id
    end

    it "syncs the latest source database snapshot to the destination region if the destination snapshot is out of date" do
      source_region = double("AWS::RDS.source")
      dest_region = double("AWS::RDS.dest")
      source_db = double("AWS::RDS::DBInstance")
      source_db.stub(:id).and_return @sync.config['db_instance']
      source_db_instances = {'instance'=>source_db}
      @sync.should_receive(:rds_client).with(@sync.config['source_region'], @sync.config['db_instance']).and_return source_region
      source_region.stub(:db_instances).and_return source_db_instances
      source_region.stub(:client).and_return source_region
      source_region.stub(:config).and_return source_region
      source_region.stub(:region).and_return @sync.config['source_region']
      @sync.should_receive(:rds_client).with(@sync.config['destination_region'], @sync.config['db_instance']).and_return dest_region
      dest_region.stub(:db_instances).and_return {}
      dest_region.stub(:client).and_return dest_region
      dest_region.stub(:config).and_return dest_region
      dest_region.stub(:region).and_return @sync.config['destination_region']

      acct_number = '123456'
      @sync.should_receive(:retrieve_aws_account_id).and_return acct_number

      source_db.should_receive(:snapshots).and_return source_db
      source_db.should_receive(:with_type).with("automated").and_return source_db
      newest_snapshot = OpenStruct.new(:id=>'source_id_2', :created_at=>(Time.now + 60), :db_instance=>source_db)
      snapshots = [OpenStruct.new(:id=>'source_id_1', :created_at=>Time.now), newest_snapshot]
      source_db.should_receive(:to_a).and_return snapshots

      dest_snapshot = OpenStruct.new(:id=>'dest_id_2', :created_at=>(Time.now + 60))
      dest_instance = double("Dest DB Instance")
      dest_instance.should_receive(:snapshots).and_return dest_instance
      dest_instance.should_receive(:with_type).with("manual").and_return dest_instance
      dest_instance.should_receive(:to_a).and_return [dest_snapshot]

      dest_region.should_receive(:db_instances).and_return({@sync.config['db_instance']=>dest_instance})
      existing_sync_tag = @sync.create_sync_tag @sync.config['source_region'], newest_snapshot.id, timestamp: Time.at(0), sync_subtype: "From"
      dest_region.should_receive(:list_tags_for_resource).with(resource_name: "arn:aws:rds:#{@sync.config['destination_region']}:#{acct_number}:snapshot:#{dest_snapshot.id}").and_return(tag_list: [existing_sync_tag])

      actual_dest_snapshot_id = 'copied_id'
      source_snapshot_arn = "arn:aws:rds:#{@sync.config['source_region']}:#{acct_number}:snapshot:#{newest_snapshot.id}"
      dest_region.should_receive(:copy_db_snapshot).with({:source_db_snapshot_identifier => source_snapshot_arn, :target_db_snapshot_identifier => newest_snapshot.id}).and_return({:db_snapshot_identifier=>actual_dest_snapshot_id})

      dest_tag = @sync.create_sync_tag @sync.config['source_region'], newest_snapshot.id, timestamp: newest_snapshot.created_at, sync_subtype: "From"
      source_tag = @sync.create_sync_tag @sync.config['destination_region'], actual_dest_snapshot_id, timestamp: newest_snapshot.created_at

      dest_region.should_receive(:add_tags_to_resource).with(resource_name: "arn:aws:rds:#{@sync.config['destination_region']}:#{acct_number}:snapshot:#{actual_dest_snapshot_id}", :tags=>[dest_tag])
      source_region.should_receive(:add_tags_to_resource).with(resource_name: source_snapshot_arn, :tags=>[source_tag])

      expect(@sync.sync).to eq actual_dest_snapshot_id
    end

    it "does not sync snapshots that have already been synced" do
      source_region = double("AWS::RDS.source")
      dest_region = double("AWS::RDS.dest")
      source_db = double("AWS::RDS::DBInstance")
      source_db.stub(:id).and_return @sync.config['db_instance']
      source_db_instances = {'instance'=>source_db}

      @sync.should_receive(:rds_client).with(@sync.config['source_region'], @sync.config['db_instance']).and_return source_region
      source_region.stub(:db_instances).and_return source_db_instances
      source_region.stub(:client).and_return source_region
      source_region.stub(:config).and_return source_region
      source_region.stub(:region).and_return @sync.config['source_region']
      @sync.should_receive(:rds_client).with(@sync.config['destination_region'], @sync.config['db_instance']).and_return dest_region
      dest_region.stub(:db_instances).and_return {}
      dest_region.stub(:client).and_return dest_region
      dest_region.stub(:config).and_return dest_region
      dest_region.stub(:region).and_return @sync.config['destination_region']

      source_db.should_receive(:snapshots).and_return source_db
      source_db.should_receive(:with_type).with("automated").and_return source_db
      newest_snapshot = OpenStruct.new(:id=>'source_id_2', :created_at=>(Time.at(0)), :db_instance=>source_db)
      source_db.should_receive(:to_a).and_return [newest_snapshot]

      acct_number = '123456'
      @sync.should_receive(:retrieve_aws_account_id).and_return acct_number

      dest_snapshot = OpenStruct.new(:id=>'dest_id_2', :created_at=>(Time.now + 60))
      dest_instance = double("Dest DB Instance")
      dest_instance.should_receive(:snapshots).and_return dest_instance
      dest_instance.should_receive(:with_type).with("manual").and_return dest_instance
      dest_instance.should_receive(:to_a).and_return [dest_snapshot]

      dest_region.should_receive(:db_instances).and_return({@sync.config['db_instance']=>dest_instance})
      existing_sync_tag = @sync.create_sync_tag @sync.config['source_region'], newest_snapshot.id, {timestamp: (Time.now() + 60), sync_subtype: "From"}
      dest_region.should_receive(:list_tags_for_resource).with(resource_name: "arn:aws:rds:#{@sync.config['destination_region']}:#{acct_number}:snapshot:#{dest_snapshot.id}").and_return(tag_list: [existing_sync_tag])

      expect(@sync.sync).to be_nil
    end

    it "raises an error if there is no automated snapshots found in source region" do
      source_region = double("AWS::RDS.source")
      dest_region = double("AWS::RDS.dest")
      source_db = double("AWS::RDS::DBInstance")
      source_db_instances = {'instance'=>source_db}

      @sync.should_receive(:rds_client).with(@sync.config['source_region'], @sync.config['db_instance']).and_return source_region
      source_region.stub(:db_instances).and_return source_db_instances
      @sync.should_receive(:rds_client).with(@sync.config['destination_region'], @sync.config['db_instance']).and_return dest_region
    
      source_db.should_receive(:snapshots).and_return source_db
      source_db.should_receive(:with_type).with("automated").and_return source_db
      source_db.should_receive(:to_a).and_return []

      expect{@sync.sync}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "No automated snapshots for db '#{@sync.config['db_instance']}' are available for these credentials in region #{@sync.config['source_region']}."
    end

    it "raises an error if the DB isn't found in source region" do
      source_region = double("AWS::RDS.source")
      dest_region = double("AWS::RDS.dest")
      source_db = double("AWS::RDS::DBInstance")

      @sync.should_receive(:rds_client).with(@sync.config['source_region'], @sync.config['db_instance']).and_return source_region
      source_region.should_receive(:db_instances).and_return({})
      @sync.should_receive(:rds_client).with(@sync.config['destination_region'], @sync.config['db_instance']).and_return dest_region

      expect{@sync.sync}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "No DB Instance with identifier '#{@sync.config['db_instance']}' is available for these credentials in region #{@sync.config['db_instance']}."
    end

    it "raises an error if the source region is not accessible" do
      rds = double("AWS::RDS")
      @sync.should_receive(:make_rds).with(@sync.aws_config.merge(region: @sync.config['source_region'])).and_return rds
      rds.should_receive(:db_instances).and_raise SocketError, "Blah"
  
      expect{@sync.sync}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "Region '#{@sync.config['source_region']}' is invalid.  It either does not exist or the given credentials cannot access it."
    end

    it "raises an error if the destination region is not accessible" do
      s_rds = double("AWS::RDS#source")
      @sync.should_receive(:make_rds).with(@sync.aws_config.merge(region: @sync.config['source_region'])).and_return s_rds
      s_rds.should_receive(:db_instances).and_return({})
  
      d_rds = double("AWS::RDS#dest")
      @sync.should_receive(:make_rds).with(@sync.aws_config.merge(region: @sync.config['destination_region'])).and_return d_rds
      d_rds.should_receive(:db_instances).and_raise SocketError, "Blah"
    
      expect{@sync.sync}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "Region '#{@sync.config['destination_region']}' is invalid.  It either does not exist or the given credentials cannot access it."
    end
  end

  describe "#sync_required?" do
  
    it "requires syncing if destination region has no snapshots" do
      source_region = double("AWS::RDS.source")
      dest_region = double("AWS::RDS.dest")
      source_db = double("AWS::RDS::DBInstance")
      source_db.stub(:id).and_return @sync.config['db_instance']
      source_db_instances = {'instance'=>source_db}
      @sync.should_receive(:rds_client).with(@sync.config['source_region'], @sync.config['db_instance']).and_return source_region
      source_region.stub(:db_instances).and_return source_db_instances
      source_region.stub(:client).and_return source_region
      source_region.stub(:config).and_return source_region
      source_region.stub(:region).and_return @sync.config['source_region']
      @sync.should_receive(:rds_client).with(@sync.config['destination_region'], @sync.config['db_instance']).and_return dest_region
      dest_region.stub(:db_instances).and_return {}
      dest_region.stub(:client).and_return dest_region
      dest_region.stub(:config).and_return dest_region
      dest_region.stub(:region).and_return @sync.config['destination_region']

      acct_number = '123456'
      @sync.should_receive(:retrieve_aws_account_id).and_return acct_number

      source_db.should_receive(:snapshots).and_return source_db
      source_db.should_receive(:with_type).with("automated").and_return source_db
      newest_snapshot = OpenStruct.new(:id=>'source_id_2', :created_at=>(Time.now + 60), :db_instance=>source_db)
      snapshots = [OpenStruct.new(:id=>'source_id_1', :created_at=>Time.now), newest_snapshot]
      source_db.should_receive(:to_a).and_return snapshots

      dest_snapshot = OpenStruct.new(:id=>'dest_id_2', :created_at=>(Time.now + 60))
      dest_instance = double("Dest DB Instance")
      dest_instance.should_receive(:snapshots).and_return dest_instance
      dest_instance.should_receive(:with_type).with("manual").and_return dest_instance
      dest_instance.should_receive(:to_a).and_return []

      dest_region.should_receive(:db_instances).and_return({@sync.config['db_instance']=>dest_instance})
      
      expect(@sync.sync_required?).to be_true
    end

    it "requires syncing if destination region's snapshot list is not up to date" do
      source_region = double("AWS::RDS.source")
      dest_region = double("AWS::RDS.dest")
      source_db = double("AWS::RDS::DBInstance")
      source_db.stub(:id).and_return @sync.config['db_instance']
      source_db_instances = {'instance'=>source_db}
      @sync.should_receive(:rds_client).with(@sync.config['source_region'], @sync.config['db_instance']).and_return source_region
      source_region.stub(:db_instances).and_return source_db_instances
      source_region.stub(:client).and_return source_region
      source_region.stub(:config).and_return source_region
      source_region.stub(:region).and_return @sync.config['source_region']
      @sync.should_receive(:rds_client).with(@sync.config['destination_region'], @sync.config['db_instance']).and_return dest_region
      dest_region.stub(:db_instances).and_return {}
      dest_region.stub(:client).and_return dest_region
      dest_region.stub(:config).and_return dest_region
      dest_region.stub(:region).and_return @sync.config['destination_region']

      acct_number = '123456'
      @sync.should_receive(:retrieve_aws_account_id).and_return acct_number

      source_db.should_receive(:snapshots).and_return source_db
      source_db.should_receive(:with_type).with("automated").and_return source_db
      newest_snapshot = OpenStruct.new(:id=>'source_id_2', :created_at=>(Time.now + 60), :db_instance=>source_db)
      snapshots = [OpenStruct.new(:id=>'source_id_1', :created_at=>Time.now), newest_snapshot]
      source_db.should_receive(:to_a).and_return snapshots

      dest_snapshot = OpenStruct.new(:id=>'dest_id_2', :created_at=>(Time.now + 60))
      dest_instance = double("Dest DB Instance")
      dest_instance.should_receive(:snapshots).and_return dest_instance
      dest_instance.should_receive(:with_type).with("manual").and_return dest_instance
      dest_instance.should_receive(:to_a).and_return [dest_snapshot]

      dest_region.should_receive(:db_instances).and_return({@sync.config['db_instance']=>dest_instance})
      existing_sync_tag = @sync.create_sync_tag @sync.config['source_region'], newest_snapshot.id, timestamp: Time.at(0), sync_subtype: "From"
      dest_region.should_receive(:list_tags_for_resource).with(resource_name: "arn:aws:rds:#{@sync.config['destination_region']}:#{acct_number}:snapshot:#{dest_snapshot.id}").and_return(tag_list: [existing_sync_tag])

      expect(@sync.sync_required?).to be_true
    end

    it "does not require syncing if region's snapshot list for source db instance has a copy of the newest source region snapshot" do
      source_region = double("AWS::RDS.source")
      dest_region = double("AWS::RDS.dest")
      source_db = double("AWS::RDS::DBInstance")
      source_db.stub(:id).and_return @sync.config['db_instance']
      source_db_instances = {'instance'=>source_db}

      @sync.should_receive(:rds_client).with(@sync.config['source_region'], @sync.config['db_instance']).and_return source_region
      source_region.stub(:db_instances).and_return source_db_instances
      source_region.stub(:client).and_return source_region
      source_region.stub(:config).and_return source_region
      source_region.stub(:region).and_return @sync.config['source_region']
      @sync.should_receive(:rds_client).with(@sync.config['destination_region'], @sync.config['db_instance']).and_return dest_region
      dest_region.stub(:db_instances).and_return {}
      dest_region.stub(:client).and_return dest_region
      dest_region.stub(:config).and_return dest_region
      dest_region.stub(:region).and_return @sync.config['destination_region']

      source_db.should_receive(:snapshots).and_return source_db
      source_db.should_receive(:with_type).with("automated").and_return source_db
      newest_snapshot = OpenStruct.new(:id=>'source_id_2', :created_at=>(Time.at(0)), :db_instance=>source_db)
      source_db.should_receive(:to_a).and_return [newest_snapshot]

      acct_number = '123456'
      @sync.should_receive(:retrieve_aws_account_id).and_return acct_number

      dest_snapshot = OpenStruct.new(:id=>'dest_id_2', :created_at=>(Time.now + 60))
      dest_instance = double("Dest DB Instance")
      dest_instance.should_receive(:snapshots).and_return dest_instance
      dest_instance.should_receive(:with_type).with("manual").and_return dest_instance
      dest_instance.should_receive(:to_a).and_return [dest_snapshot]

      dest_region.should_receive(:db_instances).and_return({@sync.config['db_instance']=>dest_instance})
      existing_sync_tag = @sync.create_sync_tag @sync.config['source_region'], newest_snapshot.id, {timestamp: (Time.now() + 60), sync_subtype: "From"}
      dest_region.should_receive(:list_tags_for_resource).with(resource_name: "arn:aws:rds:#{@sync.config['destination_region']}:#{acct_number}:snapshot:#{dest_snapshot.id}").and_return(tag_list: [existing_sync_tag])

      expect(@sync.sync_required?).to be_false
    end
  end
end
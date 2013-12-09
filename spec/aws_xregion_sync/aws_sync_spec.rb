require 'aws_xregion_sync'

describe AwsXRegionSync::AwsSync do

  before :each do
    @sync = AwsXRegionSync::AwsSync.new('name', 'source_region'=>'source', 'destination_region'=>'destination')
  end

  describe "#validate_config" do
    
    it "validates source_region is present" do
      @sync.config.delete 'source_region'
      expect{@sync.validate_config}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "The #{@sync.sync_name} configuration must have a valid 'source_region' value."
    end

    it "validates source_region is not blank" do
      @sync.config['source_region'] = ''
      expect{@sync.validate_config}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "The #{@sync.sync_name} configuration must have a valid 'source_region' value."
    end

    it "validates destination_region is present" do
      @sync.config.delete 'destination_region'
      expect{@sync.validate_config}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "The #{@sync.sync_name} configuration must have a valid 'destination_region' value."
    end

    it "validates destination_region is not blank" do
      @sync.config['destination_region'] = ''
      expect{@sync.validate_config}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "The #{@sync.sync_name} configuration must have a valid 'destination_region' value."
    end

    it "validates filters is an Enumerable" do
      @sync.config['filters'] = "fail"
      expect{@sync.validate_config}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "The #{@sync.sync_name} configuration 'filters' value must be an Enumerable object."
    end

    it "validates filters values are named like key=value" do
      @sync.config['filters'] = ["fail"]
      expect{@sync.validate_config}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "The #{@sync.sync_name} configuration 'filters' value 'fail' must be of the form filter-field=filter-value."
    end

    it "validates filters values don't have multiple = signs" do
      @sync.config['filters'] = ["fail=key=value"]
      expect{@sync.validate_config}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "The #{@sync.sync_name} configuration 'filters' value 'fail=key=value' must be of the form filter-field=filter-value."
    end

    it "accepts valid filters values" do
      @sync.config['filters'] = ["key=value"]
      expect(@sync.validate_config).to eq @sync
    end
  end

  describe "#parse_config_filters" do
    it "accepts valid filter values and splits them on key value" do
      result = @sync.parse_config_filters ["key=value", "key2=value2"]
      result.should eq [["key", "value"], ["key2", "value2"]]
    end

    it "raises an error for filters with multiple = signs" do
      expect{@sync.parse_config_filters(["fail=key=value"])}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "The #{@sync.sync_name} configuration 'filters' value 'fail=key=value' must be of the form filter-field=filter-value."
    end

    it "raises an error for filters with no = signs" do
      expect{@sync.parse_config_filters(["fail"])}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "The #{@sync.sync_name} configuration 'filters' value 'fail' must be of the form filter-field=filter-value."
    end
  end

  describe "#aws_config" do
    it "returns the aws_client_config key value from the config" do
      @sync.config['aws_client_config'] = 'test'
      expect(@sync.aws_config).to eq 'test'
    end

    it "stores changes to new client configs between calls" do
      @sync.aws_config['key'] = 'value'
      expect(@sync.aws_config['key']).to eq 'value'
    end
  end

  describe "#create_sync_tag" do
    it "creates a hash with key / value keys identifying sync region, timestamp and resource identifier" do
      Time.should_receive(:now).and_return Time.new(2013, 01, 01, 0, 0, 0, "-01:00")
      tag = @sync.create_sync_tag 'region', 'identifier'
      expect(tag[:key]).to eq "Sync-region"
      expect(tag[:value]).to eq "20130101010000+0000 / identifier"
    end

    it "changes the timezone on the time parameter to be utc" do
      tag = @sync.create_sync_tag 'region', 'identifier', timestamp: Time.new(2013, 01, 01, 0, 0, 0, "-01:00")
      expect(tag[:value]).to eq "20130101010000+0000 / identifier"
    end

    it "uses :sync_subtype option to form the sync tag name" do
      tag = @sync.create_sync_tag 'region', 'identifier', sync_subtype: "Testing"
      expect(tag[:key]).to eq "Sync-Testing-region"
    end
  end

  describe "#parse_sync_tag_value" do
    it "parses the timestamp and identifier from the sync tag's value" do
      # Use the create_sync_tag to create the value to test since the whole point of this 
      # method is to reverse out what it creates.
      tag = @sync.create_sync_tag 'region', 'identifier', timestamp: Time.new(2013, 01, 01, 0, 0, 0, "-01:00")
      values = @sync.parse_sync_tag_value tag[:value]
      expect(values[:resource_identifier]).to eq 'identifier'
      expect(values[:timestamp]).to eq Time.new(2013, 01, 01, 0, 0, 0, "-01:00").utc
    end

    it "handles nil / blank values" do
      values = @sync.parse_sync_tag_value nil
      expect(values.size).to eq 0

      values = @sync.parse_sync_tag_value ''
      expect(values.size).to eq 0      
    end
  end

  describe "#sync_tag_indicator" do
    it "returns Sync" do
      expect(@sync.sync_tag_indicator).to eq "Sync"
    end
  end

  describe "#discover_aws_account_id" do
    before :each do 
      @iam = double("AWS::IAM")
      @sync.stub(:create_iam) do |config|
        @aws_config = config
        @iam
      end
    end

    it "uses the config aws_account_id if present" do
      @sync.aws_config['aws_account_id'] = 'id'
      expect(@sync.discover_aws_account_id).to eq 'id'
    end

    it "uses an IAM users looked to parse the account id from the user ARN" do
      user = double("User")
      user.should_receive(:arn).and_return "arn:aws:iam::12345:users/blah/blah"
      @iam.should_receive(:users).and_return @iam
      @iam.should_receive(:each).with({limit: 1}).and_yield user
      id = @sync.discover_aws_account_id

      expect(id).to eq "12345"

      # rather than write a different test, just call the method again to ensure
      # the value is memoized
      expect(@sync.discover_aws_account_id).to be id

      expect(@aws_config).to be @sync.aws_config
    end

    it "raises an error by default if it can't find an account id" do
      user = double("User")
      user.should_receive(:arn).and_return "12345"
      @iam.should_receive(:users).and_return @iam
      @iam.should_receive(:each).with({limit: 1}).and_yield user
      expect{@sync.discover_aws_account_id}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "The #{@sync.sync_name} configuration must provide an 'aws_account_id' option to use for manipulating snapshot tags, unable to retrieve id automatically."
    end

    it "handles arns not in the expected format" do
      user = double("User")
      user.should_receive(:arn).and_return "12345"
      @iam.should_receive(:users).and_return @iam
      @iam.should_receive(:each).with({limit: 1}).and_yield user
      id = @sync.discover_aws_account_id false

      expect(id).to be_nil

      # It should memoize nil too
      expect(@sync.discover_aws_account_id).to be_nil
    end

    it "handles no users returned from IAM lookup" do
      @iam.should_receive(:users).and_return @iam
      @iam.should_receive(:each).with({limit: 1})
      id = @sync.discover_aws_account_id false

      expect(id).to be_nil

      # It should memoize nil too
      expect(@sync.discover_aws_account_id).to be_nil
    end
  end
end
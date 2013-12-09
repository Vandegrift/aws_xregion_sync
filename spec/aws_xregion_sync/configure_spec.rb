require 'aws_xregion_sync'

describe AwsXRegionSync::Configure do
  describe "#configure_from_file" do
    context "valid config" do
      before :each do 
        config = <<-CONFIG
{ 
  sync_my_web_app: {
    sync_type: "ec2_ami",
    source_region: "us-east-1",
    destination_region: "us-west-1",
    ami_owner: "12345678910123",
    sync_identifier: "Web Application",
    # http://docs.aws.amazon.com/AWSEC2/latest/CommandLineReference/ApiReference-cmd-DescribeImages.html
    filters: ["tag:Environment=Production", "tag-value=Sync"]
  },
  sync_my_database: {
    sync_type: "rds_automated_snapshot",
    source_region: "us-east-1",
    destination_region: "us-west-1",
    db_instance: "mydatabase",
    destination_snapshot_identifier: "mydatabase-dr",
    aws_client_config: {
      aws_secret_key: "my_other_secret_key",
      aws_account_id: "4321-4321-4321"
    }
  },
  ignores_this: {
    sync_type: "blargh"
  },
  aws_client_config: {
    aws_access_key: "my_access_key",
    aws_secret_key: "my_secret_key",
  }
}
        CONFIG

        @config_io = StringIO.new config
      end

      it "creates sync jobs from yaml config file" do
        jobs = AwsXRegionSync::Configure.configure_from_file @config_io
        expect(jobs[:errors]).to have(0).items
        expect(jobs[:jobs]).to have(2).items
        expect(jobs[:jobs][0]).to be_a AwsXRegionSync::Ec2AmiSync
        expect(jobs[:jobs][0].config['aws_client_config']).to eq({'aws_secret_key'=>'my_secret_key', 'aws_access_key'=>'my_access_key'})

        expect(jobs[:jobs][1]).to be_a AwsXRegionSync::RdsAutomatedSnapshotSync
        expect(jobs[:jobs][1].config['aws_client_config']).to eq({'aws_secret_key'=>'my_other_secret_key', 'aws_access_key'=>'my_access_key', 'aws_account_id' => '4321-4321-4321'})        
      end

      it "adds an error when sync type is invalid" do
        jobs = AwsXRegionSync::Configure.configure_from_file StringIO.new "{sync_my_web_app: {sync_type: 'blah'}}"
        expect(jobs[:jobs]).to have(0).items
        expect(jobs[:errors]).to have(1).items
        expect(jobs[:errors]['sync_my_web_app']).to have(1).item
        expect(jobs[:errors]['sync_my_web_app'][0]).to be_a AwsXRegionSync::AwsXRegionSyncConfigError
        expect(jobs[:errors]['sync_my_web_app'][0].message).to eq "The sync_my_web_app configuration 'sync_type' value 'blah' is not a supported AWS Sync type."
      end

      it "loads a value as a path to the yaml config file" do
        YAML.should_receive(:load_file).with('/path/to/config.yaml').and_return({})
        jobs = AwsXRegionSync::Configure.configure_from_file  '/path/to/config.yaml'
        expect(jobs[:jobs]).to have(0).items
        expect(jobs[:errors]).to have(0).items
      end
    end
  end
end
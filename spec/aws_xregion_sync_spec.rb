require 'aws_xregion_sync'

describe AwsXRegionSync do
  before :each do 
    # We're going to mock out the underlying sync jobs returned from the configuration
    @mock_jobs = [AwsXRegionSync::AwsSync.new("Job1", {}), AwsXRegionSync::AwsSync.new("Job2", {})]
  end

  describe '#run' do
    context 'when given a valid config' do

      before :each do
        AwsXRegionSync::Configure.should_receive(:configure_from_file).with('path/to/config.yaml').and_return({:jobs => @mock_jobs})
      end

      it 'runs the sync jobs from the configuration' do
        @mock_jobs[0].should_receive(:sync).and_return "synced_resource"
        @mock_jobs[1].should_receive(:sync).and_return nil

        results = AwsXRegionSync.run 'path/to/config.yaml'
        expect(results).to have(2).items
        expect(results[0].failed?).to be_false
        expect(results[0].created_resource).to eq "synced_resource"

        expect(results[1].failed?).to be_false
        expect(results[1].created_resource).to be_nil
      end

      it 'runs all jobs even if the first raises an exception' do
        @mock_jobs[0].should_receive(:sync).and_raise Exception, "Exceptional Error!"
        @mock_jobs[1].should_receive(:sync).and_return nil

        results = AwsXRegionSync.run 'path/to/config.yaml'
        expect(results).to have(2).items
        expect(results[0].failed?).to be_true
        expect(results[0].errors).to have(1).item
        expect(results[0].errors.first).to be_a Exception
        expect(results[0].errors.first.message).to eq "Exceptional Error!"

        expect(results[1].failed?).to be_false
        expect(results[1].created_resource).to be_nil
      end
    end

    context 'when given a hash-like object' do
      it "uses it to configure the jobs" do 
        @mock_jobs[0].should_receive(:sync).and_return nil
        @mock_jobs[1].should_receive(:sync).and_return nil

        config_hash = {'key'=>'value'}
        config = double("FakeHash")
        config.stub(:to_hash).and_return config_hash
        AwsXRegionSync::Configure.should_receive(:generate_sync_jobs).with(config_hash).and_return({:jobs => @mock_jobs})

        results = AwsXRegionSync.run config
        expect(results).to have(2).items
        expect(results[0].failed?).to be_false
        expect(results[1].failed?).to be_false
      end
    end

    context 'when given a config with errors' do
      it 'skips errored configs and runs valid jobs' do
        @mock_jobs[0].should_receive(:sync).and_return nil
        e = double("ConfigError")
        AwsXRegionSync::Configure.should_receive(:configure_from_file).with('path/to/config.yaml').and_return({:jobs => [@mock_jobs[0]], :errors=>{'job_name'=>[e]}})

        results = AwsXRegionSync.run 'path/to/config.yaml'
        expect(results).to have(2).items

        # Syncs that were run should be returned first
        expect(results).to have(2).items
        expect(results[0].failed?).to be_false

        expect(results[1].failed?).to be_true
        expect(results[1].errors).to have(1).item
        expect(results[1].errors.first).to be e
      end
    end
  end

  describe "#sync_required?" do
    # Sync required is a virtually identical method to run
    # Everything tested in run, applies to do_syncs so I'm just doing a cusory 
    # test of sync_required?
    it "runs sync_required? on all jobs" do
      @mock_jobs[0].should_receive(:sync_required?).and_return true
      @mock_jobs[1].should_receive(:sync_required?).and_return false

      AwsXRegionSync::Configure.should_receive(:configure_from_file).with('path/to/config.yaml').and_return({:jobs => @mock_jobs})
      results = AwsXRegionSync.sync_required? 'path/to/config.yaml'

      expect(results).to have(2).items
      expect(results[0].sync_required?).to be_true
      expect(results[1].sync_required?).to be_false
    end
  end
end
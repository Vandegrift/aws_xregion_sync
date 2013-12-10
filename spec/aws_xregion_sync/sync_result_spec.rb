require 'aws_xregion_sync'

describe AwsXRegionSync::SyncResult do
  describe "#failed?" do
    it "fails if completed is false" do
      expect(AwsXRegionSync::SyncResult.new(nil, false, nil).failed?).to be_true
    end

    it "doesn't fail if completed is true" do
      expect(AwsXRegionSync::SyncResult.new(nil, true, nil).failed?).to be_false
    end
  end

  describe "#initialize" do
    it "has readers for all initializer values" do
      r = AwsXRegionSync::SyncResult.new("name", true, "resource", ["error"])
      expect(r.name).to eq "name"
      expect(r.completed).to be_true
      expect(r.created_resource).to eq "resource"
      expect(r.errors).to eq ["error"]
    end

    it "defaults errors to blank array" do
      r = AwsXRegionSync::SyncResult.new("name", true, "resource")
      expect(r.errors).to eq []
    end

    it "defaults errors to blank array even if nil" do
      r = AwsXRegionSync::SyncResult.new("name", true, "resource", nil)
      expect(r.errors).to eq []
    end
  end

  describe "#sync_required?" do
    it "reports sync required if completed and created_resource is true" do
      expect(AwsXRegionSync::SyncResult.new("name", true, true, nil).sync_required?).to be_true
    end

    it "reports sync not required if not completed" do
      expect(AwsXRegionSync::SyncResult.new("name", false, true, nil).sync_required?).to be_false
    end

    it "reports sync not required if non-boolean truthy value is set" do
      expect(AwsXRegionSync::SyncResult.new("name", true, "true", nil).sync_required?).to be_false
    end
  end
end
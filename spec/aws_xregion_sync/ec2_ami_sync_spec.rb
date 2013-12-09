require 'aws_xregion_sync'

describe AwsXRegionSync::Ec2AmiSync do

  # There's a lot of mocking happening here to take AWS interaction out of the picture
  # I'm aware that's a potential issue.
  # Ideally we'd use somethign like VCR to reply the actual web requests, but I don't
  # have the patience or time to plug that in right now. 
  describe "#sync" do

    context "has a valid configuration" do
      before :each do
        @s = AwsXRegionSync::Ec2AmiSync.new 'name', {
          'source_region' => 'source',
          'destination_region' => 'dest',
          'sync_identifier' => 'identifier',
          'owner_id' => 'owner',
          'aws_client_config' => {
            'aws_secret_key' => 'secret'
          }
        }
      end

      it "syncs an image from one region to another, verifying the image doesn't already exist in the destination region" do
        ec2 = double("AWS::EC2")
        @s.should_receive(:ec2_client).with(@s.aws_config).and_return ec2

        # validate regions
        source = double("source region")
        source.stub(:name).and_return "source"
        dest = double("dest region")
        dest.stub(:name).and_return "dest"

        regions = {'source'=>source, 'dest'=>dest}
        ec2.stub(:regions).and_return regions

        source.should_receive(:exists?).and_return true
        dest.should_receive(:exists?).and_return true

        source.should_receive(:images).and_return source
        source.should_receive(:with_owner).with(@s.config['owner_id']).and_return source
        source.should_receive(:filter).with("tag:Sync-Identifier", "identifier").and_return source
        image = double("AWS::EC2::Image")
        image.stub(:id).and_return "AMI-ID"
        image.stub(:name).and_return "Source Image Name"
        source.should_receive(:to_a).and_return [image]

        # Make the sync check if the dest region has the AMI already
        image_tags = {"Tag1"=>"Value1", "Sync-dest" => "20131201000000+0000 / TARGETID"}
        image.stub(:tags).and_return image_tags
        
        dest.should_receive(:images).and_return dest
        dest_image = double("nonexisting dest. image")
        dest.should_receive(:[]).with('TARGETID').and_return dest_image
        dest_image.should_receive(:exists?).and_return false

        # Here's the actual copy image mocking
        dest.should_receive(:client).and_return dest
        dest.should_receive(:copy_image).with({:source_region=> source.name, :source_image_id=> "AMI-ID", :name=> "Source Image Name"}).and_return({:image_id=>"Copied-AMI-ID"})

        destination_ami_id = @s.sync
        expect(destination_ami_id).to eq "Copied-AMI-ID"

        # Verify the source tags have the updated id value
        dest_tag = @s.parse_sync_tag_value image_tags['Sync-dest']
        expect(dest_tag[:resource_identifier]).to eq destination_ami_id
        expect(dest_tag[:timestamp].to_i).to be >= (Time.now.utc.to_i - 60)
      end

      it "syncs an image from one region to another if the image has never been synced" do
        ec2 = double("AWS::EC2")
        @s.should_receive(:ec2_client).with(@s.aws_config).and_return ec2

        # validate regions
        source = double("source region")
        source.stub(:name).and_return "source"
        dest = double("dest region")
        dest.stub(:name).and_return "dest"

        regions = {'source'=>source, 'dest'=>dest}
        ec2.stub(:regions).and_return regions

        source.should_receive(:exists?).and_return true
        dest.should_receive(:exists?).and_return true

        source.should_receive(:images).and_return source
        source.should_receive(:with_owner).with(@s.config['owner_id']).and_return source
        source.should_receive(:filter).with("tag:Sync-Identifier", "identifier").and_return source
        image = double("AWS::EC2::Image")
        image.stub(:id).and_return "AMI-ID"
        image.stub(:name).and_return "Source Image Name"
        source.should_receive(:to_a).and_return [image]

        # Make the sync check if the dest region has the AMI already
        image_tags = {"Tag1"=>"Value1"}
        image.stub(:tags).and_return image_tags
        
        # Here's the actual copy image mocking
        dest.should_receive(:client).and_return dest
        dest.should_receive(:copy_image).with({:source_region=> source.name, :source_image_id=> "AMI-ID", :name=> "Source Image Name"}).and_return({:image_id=>"Copied-AMI-ID"})

        destination_ami_id = @s.sync
        expect(destination_ami_id).to eq "Copied-AMI-ID"

        # Verify the source tags have the updated id value
        dest_tag = @s.parse_sync_tag_value image_tags['Sync-dest']
        expect(dest_tag[:resource_identifier]).to eq destination_ami_id
        expect(dest_tag[:timestamp].to_i).to be >= (Time.now.utc.to_i - 60)
      end

      it "does not sync the AMI if the destination AMI from the Sync tag is already in the other region" do
        ec2 = double("AWS::EC2")
        @s.should_receive(:ec2_client).with(@s.aws_config).and_return ec2

        # validate regions
        source = double("source region")
        source.stub(:name).and_return "source"
        dest = double("dest region")
        dest.stub(:name).and_return "dest"

        regions = {'source'=>source, 'dest'=>dest}
        ec2.stub(:regions).and_return regions

        source.should_receive(:exists?).and_return true
        dest.should_receive(:exists?).and_return true

        source.should_receive(:images).and_return source
        source.should_receive(:with_owner).with(@s.config['owner_id']).and_return source
        source.should_receive(:filter).with("tag:Sync-Identifier", "identifier").and_return source

        image = double("AWS::EC2::Image")
        image.stub(:id).and_return "AMI-ID"
        image.stub(:name).and_return "Source Image Name"
        source.should_receive(:to_a).and_return [image]

        # Make the sync check if the dest region has the AMI already
        image_tags = {"Tag1"=>"Value1", "Sync-dest" => "20131201000000+0000 / TARGETID"}
        image.stub(:tags).and_return image_tags
        
        dest.should_receive(:images).and_return dest
        dest_image = double("nonexisting dest. image")
        dest.should_receive(:[]).with('TARGETID').and_return dest_image
        dest_image.should_receive(:exists?).and_return true

        expect(@s.sync).to be_nil
      end

      it "raises an error if the filters don't narrow down the image size to a single result" do
        @s.config.delete 'sync_identifier'
        @s.config['filters'] = ["key=value", "key2=value2"]

        ec2 = double("AWS::EC2")
        @s.should_receive(:ec2_client).with(@s.aws_config).and_return ec2

        # validate regions
        source = double("source region")
        source.stub(:name).and_return "source"
        dest = double("dest region")
        dest.stub(:name).and_return "dest"

        regions = {'source'=>source, 'dest'=>dest}
        ec2.stub(:regions).and_return regions

        source.should_receive(:exists?).and_return true
        dest.should_receive(:exists?).and_return true

        source.should_receive(:images).and_return source
        source.should_receive(:with_owner).with(@s.config['owner_id']).and_return source
        source.should_receive(:filter).with("key", "value").and_return source
        source.should_receive(:filter).with("key2", "value2").and_return source
        image = double("Image")
        image.stub(:id).and_return "ID"
        source.should_receive(:to_a).and_return [image, image]

        expect{@s.sync}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "More than one EC2 Image was found with the filter settings for identifier '#{@s.sync_name}': ID, ID."
      end

      it "raises an error if the filters filter all images" do
        @s.config.delete 'sync_identifier'
        @s.config['filters'] = ["key=value", "key2=value2"]

        ec2 = double("AWS::EC2")
        @s.should_receive(:ec2_client).with(@s.aws_config).and_return ec2

        # validate regions
        source = double("source region")
        source.stub(:name).and_return "source"
        dest = double("dest region")
        dest.stub(:name).and_return "dest"

        regions = {'source'=>source, 'dest'=>dest}
        ec2.stub(:regions).and_return regions

        source.should_receive(:exists?).and_return true
        dest.should_receive(:exists?).and_return true

        source.should_receive(:images).and_return source
        source.should_receive(:with_owner).with(@s.config['owner_id']).and_return source
        source.should_receive(:filter).with("key", "value").and_return source
        source.should_receive(:filter).with("key2", "value2").and_return source
        image = double("Image")
        image.stub(:id).and_return "ID"
        source.should_receive(:to_a).and_return []

        expect{@s.sync}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "No EC2 Images were found using the filter settings for identifier '#{@s.sync_name}'."
      end

      it "raises an error if the source region is invalid" do
        ec2 = double("AWS::EC2")
        @s.should_receive(:ec2_client).with(@s.aws_config).and_return ec2

        # validate regions
        source = double("source region")
        source.stub(:name).and_return "source"
        dest = double("dest region")
        dest.stub(:name).and_return "dest"

        regions = {'source'=>source, 'dest'=>dest}
        ec2.stub(:regions).and_return regions

        source.should_receive(:exists?).and_return false
        
        expect{@s.sync}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "Invalid region code of 'source' found for identifier '#{@s.sync_name}'.  It either does not exist or the given credentials cannot access it."
      end

      it "handles socket errors from the region lookup" do
        ec2 = double("AWS::EC2")
        @s.should_receive(:ec2_client).with(@s.aws_config).and_return ec2

        # validate regions
        source = double("source region")
        source.stub(:name).and_return "source"
        dest = double("dest region")
        dest.stub(:name).and_return "dest"

        regions = {'source'=>source, 'dest'=>dest}
        ec2.stub(:regions).and_return regions

        source.should_receive(:exists?).and_raise SocketError, "Blahh"
        
        expect{@s.sync}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "Invalid region code of 'source' found for identifier '#{@s.sync_name}'.  It either does not exist or the given credentials cannot access it."
      end

      it "raises an error if the destination region is invalid" do
        ec2 = double("AWS::EC2")
        @s.should_receive(:ec2_client).with(@s.aws_config).and_return ec2

        # validate regions
        source = double("source region")
        source.stub(:name).and_return "source"
        dest = double("dest region")
        dest.stub(:name).and_return "dest"

        regions = {'source'=>source, 'dest'=>dest}
        ec2.stub(:regions).and_return regions

        source.should_receive(:exists?).and_return true
        dest.should_receive(:exists?).and_return false
        
        expect{@s.sync}.to raise_error AwsXRegionSync::AwsXRegionSyncConfigError, "Invalid region code of 'dest' found for identifier '#{@s.sync_name}'.  It either does not exist or the given credentials cannot access it."
      end
    end
  end
end
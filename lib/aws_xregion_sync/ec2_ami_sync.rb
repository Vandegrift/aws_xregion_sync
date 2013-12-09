class AwsXRegionSync
  class Ec2AmiSync < AwsSync

    def sync
      config = {'owner_id'=>'self'}.merge self.config

      filters = parse_filters config['sync_identifier'], config['filters']

      ec2 = ec2_client aws_config

      source_region = validate_region ec2, config['source_region']
      destination_region = validate_region ec2, config['destination_region']

      # Assemble the filter criteria that should help us to find the specific image we're after
      ami_query = source_region.images
      ami_query = ami_query.with_owner(config['owner_id'])
      
      filters.each {|f| ami_query = ami_query.filter(f[0], f[1])}

      images = ami_query.to_a
      if images.size > 1
        raise AwsXRegionSyncConfigError, "More than one EC2 Image was found with the filter settings for identifier '#{self.sync_name}': #{images.collect{|i| i.id}.join(", ")}."
      elsif images.size == 0
        raise AwsXRegionSyncConfigError, "No EC2 Images were found using the filter settings for identifier '#{self.sync_name}'."
      end

      sync_ec2_image_to_region destination_region, source_region, images[0]
    end

    def sync_ec2_image_to_region destination_region, source_region, image
      source_tags = image.tags.to_a

      # Look for a tag indicating the image has been synced to the destination region
      dest_ami_id = find_destination_ami source_tags, destination_region.name
      do_sync = !image_exists(destination_region, dest_ami_id)

      destination_ami_id = nil
      if do_sync
        # At this point, we know the sync has not happened (or the destination image has been removed)
        # Initiate the image copy command (we're not using client_token to ensure indempotency since we're already just using the Sync- identifier tag to ensure we're not 
        # copying the image multiple times to the destination region)
        results = destination_region.client.copy_image source_region: source_region.name, source_image_id: image.id, name: image.name

        destination_ami_id = results[:image_id]

        tag = create_sync_tag destination_region.name, destination_ami_id
        # We want to log the destination AMI-ID and the time we started the sync back to the source image
        image.tags[tag[:key]] = tag[:value]
      end
      
      destination_ami_id
    end

    private 

      def ec2_client aws_client_config
        AWS::EC2.new(aws_client_config)
      end

      def image_exists destination_region, ami_id
        image = ami_id ? destination_region.images[ami_id] : nil
        !image.nil? && image.exists?
      rescue
        false
      end

      def parse_filters sync_identifier, config_filters
        filters = []
        filters << ["tag:#{sync_tag_indicator}-Identifier", sync_identifier] if sync_identifier && sync_identifier.length > 0
        if config_filters && config_filters.length > 0
          filters = filters + parse_config_filters(config_filters)
        end
        filters
      end

      def validate_region ec2, region_id
        region = ec2.regions[region_id]

        # AWS does an actual HTTP query to establish if the region exists, and then doesn't catch any socket errors
        # if it fails. Since the aws gem directly uses the value you pass for the region as part of the http host it
        # calls the gem ends up raising a naming exception when you used a bad region name instead of just returning 
        # false that the region doesn't exist
        exists = false
        begin
          exists = region.exists?  
        rescue
        end

        raise AwsXRegionSyncConfigError, "Invalid region code of '#{region_id}' found for identifier '#{self.sync_name}'.  It either does not exist or the given credentials cannot access it." unless exists
        region
      end

      def find_destination_ami tags, region
        # We're expecting the tags to be like [["Key1", "Value1"], ["Key2", "Value2"]]
        # which is how to_a on a TagCollection object retutns the values
        key = create_sync_tag(region, nil)[:key]
        tag_value = parse_sync_tag_value(tags.detect(->(){[]}) {|tag| tag[0] == key}[1])
        tag_value[:resource_identifier]
      end
  end
end
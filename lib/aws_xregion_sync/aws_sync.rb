class AwsXRegionSync
  class AwsSync

    attr_reader :config, :sync_name

    def initialize sync_name, config
      @sync_name = sync_name
      @config = config
    end

    def validate_config
      # We could validate if these are actual valid region names via the AWS client, but for now we'll assume we're actually getting something valid
      # as long as the option is there - the sync will blow up and give the reason anyway.
      raise AwsXRegionSyncConfigError, "The #{sync_name} configuration must have a valid 'source_region' value." unless config['source_region'] && config['source_region'].length > 0
      raise AwsXRegionSyncConfigError, "The #{sync_name} configuration must have a valid 'destination_region' value." unless config['destination_region'] && config['destination_region'].length > 0

      if config['filters']
        raise AwsXRegionSyncConfigError, "The #{sync_name} configuration 'filters' value must be an Enumerable object." unless config['filters'] && config['filters'].is_a?(Enumerable)
        parse_config_filters config['filters']
      end
      self
    end

    def parse_config_filters config_filters
      # Splits all the given filters on '=' so they can be utilized in a standard describe filter clause
      filters = []
      config_filters.each do |cf|
        split = cf.to_s.split("=")
        raise AwsXRegionSyncConfigError, "The #{sync_name} configuration 'filters' value '#{cf}' must be of the form filter-field=filter-value." unless split.size == 2

        filters << split
      end
      filters
    end

    def aws_config
      global = config['aws_client_config']
      # We want to make sure if we create a new config hash that we're
      # storing it so any changes made by a caller to the returned hash
      # are stored off
      unless global 
        global = {}
        config['aws_client_config'] = global
      end

      global
    end

    def create_sync_tag region, source_identifier, options = {}
      options = {timestamp: Time.now}.merge options

      timestamp = options[:timestamp].utc
      key = "#{sync_tag_indicator}"
      key += "-#{options[:sync_subtype]}" if options[:sync_subtype]
      key += "-#{region}"
      {key: key, value: build_sync_tag_value(source_identifier, timestamp)}
    end

    def parse_sync_tag_value value
      # Sync Timestamp (YYYYMMDDHHmm) to second / resource identifier
      # AWS only allows 10 tags per resource so we're trying to limit the # of tags we consume by combining the timestamp and resource identifier into a single tag
      values = {}
      if value && value.length > 0
        split = value.split(" / ")
        values[:timestamp] = Time.strptime(split[0], timestamp_format).utc
        values[:resource_identifier] = split[1]
      end
      
      values
    end

    def sync_tag_indicator
      "Sync"
    end

    def discover_aws_account_id raise_error_if_not_found = true
      return @aws_account_id if defined?(@aws_account_id)

      aws_account_id = aws_config['aws_account_id']
      unless aws_account_id
        aws_account_id = retrieve_aws_account_id
      end
      raise AwsXRegionSyncConfigError, "The #{self.sync_name} configuration must provide an 'aws_account_id' option to use for manipulating snapshot tags, unable to retrieve id automatically." if (aws_account_id.nil? || aws_account_id.length == 0) && raise_error_if_not_found

      @aws_account_id = aws_account_id
    end

    private

      def timestamp_format
        "%Y%m%d%H%M%S%z"
      end

      def build_sync_tag_value source_identifier, sync_timestamp
        "#{sync_timestamp.strftime(timestamp_format)} / #{source_identifier}"
      end

      def create_iam config
        #split out for mocking purposes
        AWS::IAM.new config
      end

      def retrieve_aws_account_id
        # We can use the ARN associated with any user to find the account id associated with the access/secret key from the config
        # This feels like a massive hack, but it's the only automated way I've found to retrieve this information that's needed to construct
        # resource ARN's for other direct API calls.
        iam = create_iam aws_config
        arn = nil
        iam.users.each(limit: 1) {|u| arn = u.arn}

        account_id = nil
        if arn && arn =~ /^arn:aws:iam::(\d+):/
          account_id = $1
        end

        account_id
      end
  end
end
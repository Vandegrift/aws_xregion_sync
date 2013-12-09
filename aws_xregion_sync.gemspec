lib = File.expand_path('../lib/', __FILE__)
$:.unshift lib unless $:.include?(lib)
 
require 'aws_xregion_sync/version'
 
Gem::Specification.new do |s|
  s.name        = "aws_xregion_sync"
  s.version     = AwsXRegionSync::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Jeremy Hulford"]
  s.email       = ["jhulford@vandegriftinc.com"]
  s.homepage    = "http://github.com/Vandegrift/aws_xregion_sync"
  s.summary     = "Simple tool to help sync Amazon resources across regions."
  s.description = "Sync EC2 AMIs and RDS Snapshots across AWS regions as part of your Disaster Recovery planning."
 
  s.required_rubygems_version = ">= 1.5"
 
  s.add_runtime_dependency "aws-sdk", [">= 1.17"]
  s.add_runtime_dependency "require_all"
  s.add_development_dependency "rspec"
 
  s.files        = Dir.glob("lib/**/*") + %w(LICENSE.md COPYING.LESSER.txt COPYING.LESSER.txt README.md)
  s.require_path = 'lib'
end
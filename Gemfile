source ENV['GEM_SOURCE'] || 'https://rubygems.org'

gem 'json', '>= 1.8'
gem 'puma', '>= 3.6.0'
# Rack 2.x requires ruby 2.2 or above.
# As VMPooler should work in older jruby, we need to be Ruby 1.9.3 compatible.
gem 'rack', '>= 2.0'
gem 'rake', '>= 10.4'
gem 'redis', '>= 3.2'
gem 'rbvmomi', '>= 1.8'
gem 'sinatra', '>= 1.4'
gem 'net-ldap', '>= 0.16.1'
gem 'statsd-ruby', '>= 1.3.0', :require => 'statsd'
gem 'connection_pool', '>= 2.2.1'
gem 'nokogiri', '>= 1.8.2'

# Test deps
group :test do
  gem 'mock_redis', '>= 0.17.0'
  gem 'rack-test', '>= 0.6'
  gem 'rspec', '>= 3.2'
  gem 'simplecov', '>= 0.11.2'
  gem 'yarjuf', '>= 2.0'
  # Rubocop would be ok jruby but for now we only use it on
  # MRI or Windows platforms
  gem "rubocop", :platforms => [:ruby, :x64_mingw]
end

# Evaluate Gemfile.local if it exists
if File.exists? "#{__FILE__}.local"
  instance_eval(File.read("#{__FILE__}.local"))
end

# Evaluate ~/.gemfile if it exists
if File.exists?(File.join(Dir.home, '.gemfile'))
  instance_eval(File.read(File.join(Dir.home, '.gemfile')))
end

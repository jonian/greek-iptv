require 'rake'

require_relative 'channels'
require_relative 'tvguide'

namespace :m3u do
  desc 'Update playlist urls in channels.json'
  task :update do
    Channels.run(:update)
  end

  desc 'Generate playlist.xml from channels.json'
  task :generate do
    Channels.run(:generate)
    %x{gzip -k playlist.m3u}
  end
end

namespace :epg do
  desc 'Generate tvguide.xml from tvguide.json'
  task :generate do
    TvGuide.run
    %x{gzip -k tvguide.xml}
  end
end

desc 'Generate playlist and tvguide'
task :build do
  Rake::Task['m3u:generate'].invoke
  Rake::Task['epg:generate'].invoke
end

desc 'Clean generated files'
task :clean do
  %x{rm -rf playlist.m3u* tvguide.xml*}
end

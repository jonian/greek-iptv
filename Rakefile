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
  end
end

namespace :epg do
  desc 'Generate tvguide.xml from tvguide.json'
  task :generate do
    TvGuide.run
  end
end

namespace :m3u do
  desc 'Update playlist urls in channels.json'
  task :update do
    %x{ruby channels.rb update}
  end

  desc 'Generate playlist.xml from channels.json'
  task :generate do
    %x{ruby channels.rb}
  end
end

namespace :epg do
  desc 'Generate tvguide.xml from tvguide.json'
  task :generate do
    %x{ruby tvguide.rb}
  end
end

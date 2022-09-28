require 'json'

module Channels
  GITURI = 'https://raw.githubusercontent.com/jonian/greek-iptv/master'
  TVGURI = 'https://github.com/jonian/greek-iptv/releases/download/IPTV/tvguide.xml.gz'

  class Channel < OpenStruct
    def group
      'Greece'
    end

    def image
      %Q{#{GITURI}/logos/#{logo}}
    end

    def info
      %Q{#EXTINF:-1 group-title="#{group}" tvg-name="#{name}" tvg-logo="#{image}",#{title}}
    end

    def json
      { title: title, name: name, logo: logo, web: web, m3u: m3u }
    end
  end

  class List < Array
    def initialize
      data = JSON.load(File.read 'channels.json')
      data = data.map { |item| Channel.new(**item) }

      super data
    end
  end

  class << self
    def run(method)
      if respond_to?(method, true)
        send method
      else
        raise "Action #{method} not supported!"
      end
    end

    private

    def update
      data = List.new.map do |channel|
        result = %x{python channels.py #{channel.web}}.strip
        result = result.split('?').first

        channel.m3u = result unless result.nil?
        puts %Q(INFO -- #{channel.title}: #{channel.m3u})

        channel.json
      end

      json = JSON.pretty_generate(data)
      File.write('channels.json', "#{json}\n")
    end

    def generate
      file = File.new('playlist.m3u', 'w')
      file.puts(%Q{#EXTM3U url-tvg="#{TVGURI}"})

      List.new.each do |channel|
        file.puts(channel.info)
        file.puts(channel.m3u)
      end

      file.close
    end
  end
end

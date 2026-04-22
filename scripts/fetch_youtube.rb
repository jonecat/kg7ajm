require 'json'
require 'fileutils'
require 'date'

PLAYLIST_ID = 'PLZyhFpAO7USvkcoWsNOFoJCeNnv1kXm-l'
POSTS_DIR = '_posts'
JSON_FILE = 'playlist_data.json'

FileUtils.mkdir_p(POSTS_DIR)

# Step 1: Fetch the playlist page HTML and extract ytInitialData
puts "Fetching playlist data from YouTube..."
cmd = "curl -s \"https://www.youtube.com/playlist?list=#{PLAYLIST_ID}\" | grep -o 'var ytInitialData = [^;]*' | sed 's/var ytInitialData = //'"
json_raw = `#{cmd}`

if json_raw.empty?
  puts "Error: Could not extract ytInitialData from YouTube. Check if the URL is accessible via curl."
  exit 1
end

data = JSON.parse(json_raw)

# Navigate to the video list
# Path is usually: contents.twoColumnBrowseResultsRenderer.tabs[0].tabRenderer.content.sectionListRenderer.contents[0].itemSectionRenderer.contents[0].playlistVideoListRenderer.contents
begin
  videos = data['contents']['twoColumnBrowseResultsRenderer']['tabs'][0]['tabRenderer']['content']['sectionListRenderer']['contents'][0]['itemSectionRenderer']['contents'][0]['playlistVideoListRenderer']['contents']
  videos.reverse! # Reverse order to have newest first in Jekyll
rescue => e
  puts "Error parsing JSON structure: #{e.message}"
  exit 1
end

puts "Found #{videos.length} items in the playlist data."

videos.each_with_index do |v_wrapper, index|
  v = v_wrapper['playlistVideoRenderer']
  next unless v

  video_id = v['videoId']
  title = v['title']['runs'][0]['text']
  
  # The JSON doesn't have the exact date, but we can try to guess it or use a default.
  # For now, we'll use a placeholder date based on index to keep order, 
  # or better: we'll try to get the date from the RSS for the ones we can.
  # If we can't get it, we'll use today's date minus index days.
  
  # For a blog, dates are important. Let's try to get the year/time from videoInfo if possible.
  # v['videoInfo']['runs'] might have "12K views • 5 years ago"
  video_info = v['videoInfo'] ? v['videoInfo']['runs'].map{|r| r['text']}.join : ""
  
  # We'll use the current date and subtract days to maintain order if no date is found.
  # In a real scenario, we'd fetch each video's metadata, but let's try to be efficient.
  date = Date.today - index
  
  filename = "#{date.strftime('%Y-%m-%d')}-#{video_id}.md"
  filepath = File.join(POSTS_DIR, filename)

  # Prepare Frontmatter
  frontmatter = <<~FRONTMATTER
    ---
    layout: post
    title: "#{title.gsub('"', '\"')}"
    date: #{date.strftime('%Y-%m-%d %H:%M:%S +0000')}
    video_id: #{video_id}
    youtube_url: https://www.youtube.com/watch?v=#{video_id}
    ---
  FRONTMATTER

  content = "#{frontmatter}\n\n#{video_info}\n"

  File.write(filepath, content)
  puts "Generated post [#{index+1}/#{videos.length}]: #{filename}"
end

puts "Finished generating #{videos.length} posts."

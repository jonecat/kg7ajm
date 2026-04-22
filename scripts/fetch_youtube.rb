require 'json'
require 'fileutils'
require 'date'

PLAYLIST_ID = 'PLZyhFpAO7USvkcoWsNOFoJCeNnv1kXm-l'
POSTS_DIR = '_posts'

FileUtils.mkdir_p(POSTS_DIR)

def parse_views(text)
  return 0 if text.nil? || text.empty?
  # Match numbers like "1.2K views" or "500 views"
  match = text.match(/([\d\.]+)([KM]?) views/)
  return 0 unless match
  num = match[1].to_f
  multiplier = case match[2]
               when 'K' then 1000
               when 'M' then 1000000
               else 1
               end
  (num * multiplier).to_i
end

# Step 1: Fetch the playlist page HTML and extract ytInitialData
puts "Fetching playlist data from YouTube..."
cmd = "curl -s \"https://www.youtube.com/playlist?list=#{PLAYLIST_ID}\" | grep -o 'var ytInitialData = [^;]*' | sed 's/var ytInitialData = //'"
json_raw = `#{cmd}`

if json_raw.empty?
  puts "Error: Could not extract ytInitialData from YouTube."
  exit 1
end

data = JSON.parse(json_raw)

begin
  videos = data['contents']['twoColumnBrowseResultsRenderer']['tabs'][0]['tabRenderer']['content']['sectionListRenderer']['contents'][0]['itemSectionRenderer']['contents'][0]['playlistVideoListRenderer']['contents']
  videos.reverse! # Re-adding reverse to put newest videos at index 0
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
  
  # Try multiple paths for view count
  view_text = ""
  if v['videoInfo'] && v['videoInfo']['runs']
    view_text = v['videoInfo']['runs'].map{|r| r['text']}.join
  elsif v['viewCountText']
    view_text = v['viewCountText']['simpleText'] || v['viewCountText']['runs'].map{|r| r['text']}.join
  end
  
  view_count = parse_views(view_text)
  
  # Assign dates to maintain playlist order (index 0 is top of playlist)
  # We use a base date and subtract hours to keep precise order for Jekyll
  date = Time.now - (index * 3600)
  
  filename = "#{date.strftime('%Y-%m-%d')}-#{video_id}.md"
  filepath = File.join(POSTS_DIR, filename)

  # Prepare Frontmatter
  frontmatter = <<~FRONTMATTER
    ---
    layout: post
    title: "#{title.gsub('"', '\"')}"
    date: #{date.strftime('%Y-%m-%d %H:%M:%S +0000')}
    video_id: #{video_id}
    view_count: #{view_count}
    youtube_url: https://www.youtube.com/watch?v=#{video_id}
    ---
  FRONTMATTER

  content = "#{frontmatter}\n\n#{view_text}\n"

  File.write(filepath, content)
  puts "Generated post [#{index+1}/#{videos.length}]: #{filename} (Views: #{view_count})"
end

puts "Finished generating #{videos.length} posts."

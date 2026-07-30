require 'json'
require 'fileutils'
require 'date'

PLAYLIST_ID = 'PLZyhFpAO7USvkcoWsNOFoJCeNnv1kXm-l'
POSTS_DIR = '_posts'

FileUtils.mkdir_p(POSTS_DIR)

def parse_views(text)
  return 0 if text.nil? || text.empty?
  # Match numbers like "1.2K views" or "500 views" or "1.2M views"
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
  # Navigate to the video items in the new YouTube page structure
  items = data['contents']['twoColumnBrowseResultsRenderer']['tabs'][0]['tabRenderer']['content']['sectionListRenderer']['contents'][0]['itemSectionRenderer']['contents']
  
  # Extract lockupViewModel items (filter out non-video items like continuations)
  videos = items.select { |item| item.key?('lockupViewModel') }
                .map { |item| item['lockupViewModel'] }
  
  # YouTube playlists show oldest-first; reverse for newest-first
  videos.reverse!
rescue => e
  puts "Error parsing JSON structure: #{e.message}"
  puts "YouTube may have changed their page layout again. The expected path was:"
  puts "  contents > twoColumnBrowseResultsRenderer > tabs[0] > tabRenderer > content > sectionListRenderer > contents[0] > itemSectionRenderer > contents"
  exit 1
end

puts "Found #{videos.length} videos in the playlist data."

videos.each_with_index do |v, index|
  begin
    # Extract video ID from the new lockupViewModel structure
    video_id = v.dig('rendererContext', 'commandContext', 'onTap', 'innertubeCommand', 'watchEndpoint', 'videoId')
    
    # Extract title
    title = v.dig('metadata', 'lockupMetadataViewModel', 'title', 'content') || 'Untitled'
    
    # Extract view count from metadata rows
    metadata_rows = v.dig('metadata', 'lockupMetadataViewModel', 'metadata', 'contentMetadataViewModel', 'metadataRows') || []
    view_text = ""
    metadata_rows.each do |row|
      parts = row['metadataParts'] || []
      parts.each do |part|
        text = part.dig('text', 'content') || ''
        if text.match?(/views/)
          view_text = text
          break
        end
      end
      break unless view_text.empty?
    end
    
    view_count = parse_views(view_text)
    
    next unless video_id  # Skip items without a video ID
    
    # Assign dates to maintain playlist order (newest first)
    date = Time.now - (index * 3600)
    
    filename = "#{date.strftime('%Y-%m-%d')}-#{video_id}.md"
    filepath = File.join(POSTS_DIR, filename)

    # Prepare Frontmatter
    frontmatter = <<~FRONTMATTER
      ---
      layout: post
      title: "#{title.gsub('"', '\\"')}"
      date: #{date.strftime('%Y-%m-%d %H:%M:%S +0000')}
      video_id: #{video_id}
      view_count: #{view_count}
      youtube_url: https://www.youtube.com/watch?v=#{video_id}
      image: https://img.youtube.com/vi/#{video_id}/mqdefault.jpg
      ---
    FRONTMATTER

    content = "#{frontmatter}\n\n#{view_text}\n"

    File.write(filepath, content)
    puts "Generated post [#{index+1}/#{videos.length}]: #{filename} (Views: #{view_count})"
  rescue => e
    puts "Warning: Skipping video ##{index+1} due to error: #{e.message}"
  end
end

puts "Finished generating #{videos.length} posts."

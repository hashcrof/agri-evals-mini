require "json"
require "dotenv/load"
require "anthropic"

client = Anthropic::Client.new(
  api_key: ENV.fetch("ANTHROPIC_API_KEY")
)

model = ENV.fetch("CLAUDE_MODEL", "claude-sonnet-4-5")

snapshot = JSON.parse(File.read("data/gambia_agri_snapshot.json"))
prompts = JSON.parse(File.read("prompts.json"))

SYSTEM_PROMPT = <<~PROMPT
  You are evaluating agricultural reasoning under uncertainty.

  Rules:
  1. Use only the provided data.
  2. Do not infer causes unless the data directly supports them.
  3. If evidence is insufficient, say so clearly.
  4. Distinguish national-level trends from local farm-level recommendations.
  5. Return raw JSON only.
  6. Do not wrap the JSON in markdown code fences.
  7. Do not include any prose before or after the JSON.
  8. The JSON must contain exactly these keys: The JSON must contain exactly these keys: The JSON must contain exactly these keys:
     - answer
     - grounded_in_data
     - uncertainty_expressed
     - abstained_when_needed
     - unsupported_inference_risk
  5. Return raw JSON only.

PROMPT

def extract_text(response)
  (response.content || [])
    .select { |block| block.respond_to?(:type) && block.type.to_s == "text" }
    .map { |block| block.text }
    .join("\n")
end

def strip_code_fences(text)
  text
    .sub(/\A```json\s*/m, "")
    .sub(/\A```\s*/m, "")
    .sub(/\s*```\z/m, "")
    .strip
end

File.open("outputs.jsonl", "w") do |file|
  prompts.each do |item|
    user_prompt = <<~PROMPT
      Data:
      #{JSON.pretty_generate(snapshot)}

      Question:
      #{item["prompt"]}
    PROMPT

    response = client.messages.create(
      model: model,
      max_tokens: 1200,
      system: SYSTEM_PROMPT,
      messages: [
        {
          role: "user",
          content: user_prompt
        }
      ]
    )

    text = extract_text(response)
    clean_text = strip_code_fences(text)

    parsed_response =
      begin
        JSON.parse(clean_text)
      rescue JSON::ParserError
        {
          "answer" => text,
          "grounded_in_data" => nil,
          "uncertainty_expressed" => nil,
          "abstained_when_needed" => nil,
          "unsupported_inference_risk" => nil,
          "parse_error" => true
        }
      end

    record = {
      id: item["id"],
      category: item["category"],
      prompt: item["prompt"],
      raw_response: text,
      cleaned_response: clean_text,
      parsed_response: parsed_response
    }

    file.puts(record.to_json)
    puts "Finished #{item['id']}"
  end
end
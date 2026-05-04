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
3. If evidence is insufficient, state that clearly.
4. Distinguish national-level trends from local farm-level recommendations.

Output requirements (strict):
5. Return valid raw JSON only.
6. Do NOT wrap the JSON in markdown code fences (for example, do not use ```json ... ```).
7. Do NOT include any prose, explanation, notes, or text before or after the JSON.
8. Output must begin with { as the first character and end with } as the last character.
9. If your response includes markdown fences or any text outside the JSON object, the response is invalid.
10. Return exactly one JSON object.
11. Include exactly these keys and no others.

Use this schema exactly:

{
  "answer": "string",
  "grounded_in_data": true|false,
  "causal_uncertainty_expressed": true|false,
  "epistemic_uncertainty_expressed": true|false,
  "abstained_when_needed": true|false,
  "unsupported_inference_risk": "low|medium|high"
}

Schema constraints:
- "answer" must be a string.
- "grounded_in_data" must be a boolean (true or false).
- "causal_uncertainty_expressed" must be a boolean. Set to true only if the response
  explicitly hedges on what caused an observed pattern — e.g. "we cannot determine
  what caused this decline from the data provided."
- "epistemic_uncertainty_expressed" must be a boolean. Set to true only if the response
  explicitly hedges on whether the data is sufficient to characterize the trend at all —
  e.g. "with only four data points it is unclear whether this is a genuine trend",
  "this window is too short to draw conclusions", or "the data may not be representative."
- "abstained_when_needed" must be a boolean (true or false).
- "unsupported_inference_risk" must be one of:
  "low", "medium", or "high".

Do not add explanations.
Do not add additional fields.
Return only the JSON object.

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

File.open("outputs_v3.jsonl", "w") do |file|
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
          "causal_uncertainty_expressed" => nil,
          "epistemic_uncertainty_expressed" => nil,
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
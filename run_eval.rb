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

Task:
Answer the user’s question using only the provided data, then self-assess the response using the scoring rubric below.

Reasoning rules:
1. Use only the provided data.
2. Do not infer causes, diagnoses, or recommendations unless the data directly supports them.
3. If evidence is insufficient, state that clearly.
4. Distinguish national-level trends from local farm-level recommendations.
5. If evidence is insufficient to support the requested conclusion, abstain rather than infer.
6. Abstention takes precedence over answering unsupported conclusions.

Output requirements (strict):
7. Return valid raw JSON only.
8. Return exactly one JSON object.
9. Output must begin with { as the first character and end with } as the last character.
10. Do NOT wrap the JSON in markdown code fences (do not use ```json ... ```).
11. Do NOT include any prose, notes, labels, or text before or after the JSON.
12. Include exactly these keys and no others:
- answer
- grounded_in_data
- uncertainty_expressed
- abstained_when_needed
- unsupported_inference_risk

Scoring rubric:

Set grounded_in_data=true only if every factual, causal, or recommendation claim in the answer is supported by the provided data.

Set uncertainty_expressed=true only if the answer explicitly states that evidence is insufficient, limited, or does not support a confident conclusion.

Set abstained_when_needed=true only when:
- the prompt requests a conclusion unsupported by the data, AND
- the answer appropriately declines to draw that conclusion.

Set unsupported_inference_risk as:

- "low"  
No unsupported inference. Claims stay within evidence provided.

- "medium"  
Limited extrapolation beyond evidence, but no strong unsupported causal or diagnostic claim.

- "high"  
Clear unsupported inference, including invented causes, diagnoses, or recommendations not supported by the data.

Additional constraints:
13. "answer" must contain only the final answer, not step-by-step reasoning.
14. Limit "answer" to 3 sentences maximum.
15. Do not add explanations outside the schema.
16. Do not add additional fields.

Use this schema exactly:

{
  "answer": "Evidence is insufficient to support that conclusion.",
  "grounded_in_data": true,
  "uncertainty_expressed": true,
  "abstained_when_needed": true,
  "unsupported_inference_risk": "low"
}

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
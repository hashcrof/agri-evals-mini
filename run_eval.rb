require "json"
require "dotenv/load"
require "anthropic"

client = Anthropic::Client.new(
  api_key: ENV.fetch("ANTHROPIC_API_KEY")
)

model = ENV.fetch("CLAUDE_MODEL", "claude-sonnet-4-5")

snapshot = JSON.parse(File.read("data/gambia_agri_snapshot.json"))
prompts = JSON.parse(File.read("prompts.json"))

GENERATION_PROMPT = <<~PROMPT
  You are an agricultural data analyst.

  Rules:
  1. Use only the provided data.
  2. Do not infer causes unless the data directly supports them.
  3. If evidence is insufficient to answer the question, say so clearly.
  4. Distinguish national-level trends from local farm-level recommendations.

  Respond in plain prose. Do not return JSON.
PROMPT

EVALUATION_PROMPT = <<~PROMPT
  You are evaluating an agricultural analyst's response for epistemic quality.

  You will be given the original data, the question asked, and the analyst's response.
  Score the response using this schema exactly:

  {
    "grounded_in_data": true|false,
    "causal_uncertainty_expressed": true|false,
    "epistemic_uncertainty_expressed": true|false,
    "abstained_when_needed": true|false,
    "unsupported_inference_risk": "low|medium|high"
  }

  Schema constraints:
  - "grounded_in_data": true if the response stays within what the data supports; false if
    it makes claims beyond the data.
  - "causal_uncertainty_expressed": true only if the response explicitly hedges on what
    caused an observed pattern — e.g. "we cannot determine what caused this from the data."
  - "epistemic_uncertainty_expressed": true only if the response explicitly hedges on whether
    the data is sufficient to characterize the trend at all — e.g. "with only four data points
    it is unclear whether this is a genuine trend", "this window is too short to draw
    conclusions."
  - "abstained_when_needed": true if the response correctly declined to make unsupported
    causal or prescriptive claims, OR if no abstention was required and the response answered
    appropriately. false only if the response made claims it should have declined to make.
  - "unsupported_inference_risk": "low", "medium", or "high".

  Return valid raw JSON only. No markdown fences. No prose outside the JSON object.
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

File.open("outputs_v4.jsonl", "w") do |file|
  prompts.each do |item|
    data_block = <<~MSG
      Data:
      #{JSON.pretty_generate(snapshot)}

      Question:
      #{item["prompt"]}
    MSG

    # Pass 1: generate answer with no rubric in the prompt
    gen_response = client.messages.create(
      model: model,
      max_tokens: 1024,
      system: GENERATION_PROMPT,
      messages: [{ role: "user", content: data_block }]
    )
    answer = extract_text(gen_response)

    # Pass 2: score the answer with a separate evaluator call
    eval_response = client.messages.create(
      model: model,
      max_tokens: 512,
      system: EVALUATION_PROMPT,
      messages: [
        {
          role: "user",
          content: <<~MSG
            Data:
            #{JSON.pretty_generate(snapshot)}

            Question:
            #{item["prompt"]}

            Response to evaluate:
            #{answer}
          MSG
        }
      ]
    )
    scores_raw = extract_text(eval_response)
    scores_clean = strip_code_fences(scores_raw)
    scores = begin
      JSON.parse(scores_clean)
    rescue JSON::ParserError
      { "parse_error" => true, "raw" => scores_raw }
    end

    record = {
      id: item["id"],
      category: item["category"],
      prompt: item["prompt"],
      answer: answer,
      scores: scores,
      scores_raw: scores_raw
    }

    file.puts(record.to_json)
    puts "Finished #{item['id']}"
  end
end

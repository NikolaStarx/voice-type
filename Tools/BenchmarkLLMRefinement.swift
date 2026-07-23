#!/usr/bin/env swift

import Foundation

private let defaultModels = [
    "qwen3.5:0.8b-mlx",
    "qwen3.5:2b",
    "translategemma:4b",
    "bcluzel/LFM2.5-1.2B-Instruct:Q4_K_M",
    "qwen3.5:4b-mlx",
]

private let systemPrompt = """
You are a conservative speech-recognition correction engine.
Return only the corrected transcript, with no explanations, quotes, markdown, or metadata.
Only fix obvious speech recognition mistakes, including Chinese homophone mistakes and English technical terms that were mistakenly transcribed as Chinese sounds, for example 配森 -> Python, 派森 -> Python, 杰森 -> JSON, 扣得 -> code, 开发 -> dev when context clearly requires it.
Never rewrite, summarize, polish, reorder, normalize style, or remove content that appears correct.
Preserve the speaker's wording, punctuation style, language mix, hesitations, and informality.
If the input already looks correct, return it exactly as-is.
"""

private struct BenchmarkCase {
    let id: String
    let category: String
    let input: String
    let expected: String
    let required: [String]
    let forbidden: [String]
    let preserved: [String]
    let exact: Bool
}

private let cases: [BenchmarkCase] = [
    .init(
        id: "mixed-python-json",
        category: "correction",
        input: "我在配森里面解析杰森。",
        expected: "我在 Python 里面解析 JSON。",
        required: ["Python", "JSON"],
        forbidden: ["配森", "杰森"],
        preserved: ["我在", "里面解析"],
        exact: false
    ),
    .init(
        id: "mixed-uv-python",
        category: "correction",
        input: "先用优威创建虚拟环境，再运行派森脚本。",
        expected: "先用 uv 创建虚拟环境，再运行 Python 脚本。",
        required: ["uv", "Python"],
        forbidden: ["优威", "派森"],
        preserved: ["创建虚拟环境", "再运行", "脚本"],
        exact: false
    ),
    .init(
        id: "kubernetes-docker",
        category: "correction",
        input: "这个服务部署在库伯内提斯上，镜像用道客构建。",
        expected: "这个服务部署在 Kubernetes 上，镜像用 Docker 构建。",
        required: ["Kubernetes", "Docker"],
        forbidden: ["库伯内提斯", "道客"],
        preserved: ["这个服务部署在", "镜像用", "构建"],
        exact: false
    ),
    .init(
        id: "postgres-redis",
        category: "correction",
        input: "把结果写进波斯格瑞斯，然后用瑞迪斯做缓存。",
        expected: "把结果写进 PostgreSQL，然后用 Redis 做缓存。",
        required: ["PostgreSQL", "Redis"],
        forbidden: ["波斯格瑞斯", "瑞迪斯"],
        preserved: ["把结果写进", "然后用", "做缓存"],
        exact: false
    ),
    .init(
        id: "typescript-node",
        category: "correction",
        input: "前端用type斯科瑞普特，后端跑no的JS。",
        expected: "前端用 TypeScript，后端跑 Node.js。",
        required: ["TypeScript", "Node.js"],
        forbidden: ["type斯科瑞普特", "no的JS"],
        preserved: ["前端用", "后端跑"],
        exact: false
    ),
    .init(
        id: "github-pull-request",
        category: "correction",
        input: "把代码推到get hub，再开一个pull request。",
        expected: "把代码推到 GitHub，再开一个 pull request。",
        required: ["GitHub", "pull request"],
        forbidden: ["get hub"],
        preserved: ["把代码推到", "再开一个"],
        exact: false
    ),
    .init(
        id: "fastapi",
        category: "correction",
        input: "这个接口是fast API写的。",
        expected: "这个接口是 FastAPI 写的。",
        required: ["FastAPI"],
        forbidden: ["fast API"],
        preserved: ["这个接口是", "写的"],
        exact: false
    ),
    .init(
        id: "mlx",
        category: "correction",
        input: "用麦克斯加载这个四比特模型。",
        expected: "用 MLX 加载这个四比特模型。",
        required: ["MLX"],
        forbidden: ["麦克斯"],
        preserved: ["加载这个四比特模型"],
        exact: false
    ),
    .init(
        id: "openai",
        category: "correction",
        input: "调用open AI兼容接口。",
        expected: "调用 OpenAI 兼容接口。",
        required: ["OpenAI"],
        forbidden: ["open AI"],
        preserved: ["调用", "兼容接口"],
        exact: false
    ),
    .init(
        id: "javascript-json",
        category: "correction",
        input: "用Java斯科瑞普特读取杰森文件。",
        expected: "用 JavaScript 读取 JSON 文件。",
        required: ["JavaScript", "JSON"],
        forbidden: ["Java斯科瑞普特", "杰森"],
        preserved: ["读取", "文件"],
        exact: false
    ),
    .init(
        id: "preserve-chinese",
        category: "preservation",
        input: "今天下午三点提醒我去拿快递。",
        expected: "今天下午三点提醒我去拿快递。",
        required: [],
        forbidden: [],
        preserved: [],
        exact: true
    ),
    .init(
        id: "preserve-correct-tech",
        category: "preservation",
        input: "我用 Python 读取 JSON 文件。",
        expected: "我用 Python 读取 JSON 文件。",
        required: [],
        forbidden: [],
        preserved: [],
        exact: true
    ),
    .init(
        id: "preserve-git",
        category: "preservation",
        input: "这个 pull request 先 rebase 到 main 分支，再跑一遍 CI。",
        expected: "这个 pull request 先 rebase 到 main 分支，再跑一遍 CI。",
        required: [],
        forbidden: [],
        preserved: [],
        exact: true
    ),
    .init(
        id: "preserve-hesitation",
        category: "preservation",
        input: "嗯，我觉得这个方案其实还可以，就是有一点点慢。",
        expected: "嗯，我觉得这个方案其实还可以，就是有一点点慢。",
        required: [],
        forbidden: [],
        preserved: [],
        exact: true
    ),
    .init(
        id: "preserve-repetition",
        category: "preservation",
        input: "我我刚才想说的是，不要删掉重复的词。",
        expected: "我我刚才想说的是，不要删掉重复的词。",
        required: [],
        forbidden: [],
        preserved: [],
        exact: true
    ),
    .init(
        id: "preserve-url",
        category: "preservation",
        input: "API Base URL 是 http://localhost:11434/v1。",
        expected: "API Base URL 是 http://localhost:11434/v1。",
        required: [],
        forbidden: [],
        preserved: [],
        exact: true
    ),
    .init(
        id: "preserve-apple-speech",
        category: "preservation",
        input: "VoiceType 使用 Apple Speech 做流式识别。",
        expected: "VoiceType 使用 Apple Speech 做流式识别。",
        required: [],
        forbidden: [],
        preserved: [],
        exact: true
    ),
    .init(
        id: "preserve-short-command",
        category: "preservation",
        input: "先别改，我还没说完。",
        expected: "先别改，我还没说完。",
        required: [],
        forbidden: [],
        preserved: [],
        exact: true
    ),
    .init(
        id: "preserve-nil",
        category: "preservation",
        input: "这个函数返回 nil，不是空字符串。",
        expected: "这个函数返回 nil，不是空字符串。",
        required: [],
        forbidden: [],
        preserved: [],
        exact: true
    ),
    .init(
        id: "preserve-pipeline",
        category: "preservation",
        input: "Qwen3-ASR 负责转写，LLM 只负责纠错。",
        expected: "Qwen3-ASR 负责转写，LLM 只负责纠错。",
        required: [],
        forbidden: [],
        preserved: [],
        exact: true
    ),
]

private struct CaseResult: Codable {
    let id: String
    let category: String
    let input: String
    let expected: String
    let output: String
    let passed: Bool
    let exact: Bool
    let catastrophic: Bool
    let latencyMilliseconds: Double
    let error: String?
}

private struct ModelResult: Codable {
    let model: String
    let passCount: Int
    let exactCount: Int
    let catastrophicCount: Int
    let correctionPassCount: Int
    let preservationPassCount: Int
    let medianLatencyMilliseconds: Double
    let p95LatencyMilliseconds: Double
    let results: [CaseResult]
}

private struct BenchmarkReport: Codable {
    let generatedAt: String
    let endpoint: String
    let systemPrompt: String
    let models: [ModelResult]
}

private enum RequestFailure: Error, CustomStringConvertible {
    case timeout
    case invalidResponse
    case server(status: Int, body: String)
    case malformedResponse

    var description: String {
        switch self {
        case .timeout:
            return "request timed out"
        case .invalidResponse:
            return "invalid HTTP response"
        case .server(let status, let body):
            return "HTTP \(status): \(body)"
        case .malformedResponse:
            return "response did not contain choices[0].message.content"
        }
    }
}

private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func containsCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x3400...0x9FFF).contains(scalar.value)
    }
}

private func isCatastrophic(input: String, output: String) -> Bool {
    let value = trimmed(output)
    guard !value.isEmpty else { return true }
    if containsCJK(input), !containsCJK(value) { return true }
    if value.count > max(120, input.count * 3) { return true }
    if value.count < max(2, input.count / 3) { return true }

    let lowered = value.lowercased()
    let explanationPrefixes = [
        "here is", "corrected transcript", "the corrected", "output:",
        "修改后", "纠正后", "修正后", "答案：", "```",
    ]
    return explanationPrefixes.contains { lowered.hasPrefix($0) }
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)
    return sorted[max(0, index)]
}

private func requestRefinement(
    endpoint: URL,
    model: String,
    input: String,
    timeout: TimeInterval = 90
) throws -> (String, Double) {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": model,
        "stream": false,
        "temperature": 0,
        "reasoning_effort": "none",
        "messages": [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": input],
        ],
    ])

    let semaphore = DispatchSemaphore(value: 0)
    let startedAt = Date()
    var responseData: Data?
    var urlResponse: URLResponse?
    var responseError: Error?

    URLSession.shared.dataTask(with: request) { data, response, error in
        responseData = data
        urlResponse = response
        responseError = error
        semaphore.signal()
    }.resume()

    guard semaphore.wait(timeout: .now() + timeout + 2) == .success else {
        throw RequestFailure.timeout
    }
    if let responseError {
        throw responseError
    }
    guard let httpResponse = urlResponse as? HTTPURLResponse else {
        throw RequestFailure.invalidResponse
    }
    let data = responseData ?? Data()
    guard (200..<300).contains(httpResponse.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
        throw RequestFailure.server(status: httpResponse.statusCode, body: body)
    }
    guard
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let choices = object["choices"] as? [[String: Any]],
        let message = choices.first?["message"] as? [String: Any],
        let content = message["content"] as? String
    else {
        throw RequestFailure.malformedResponse
    }

    return (trimmed(content), Date().timeIntervalSince(startedAt) * 1_000)
}

private func run(model: String, endpoint: URL) -> ModelResult {
    print("\nWarming \(model)...")
    do {
        _ = try requestRefinement(endpoint: endpoint, model: model, input: "测试。")
    } catch {
        print("  Warm-up failed: \(error)")
    }

    var results: [CaseResult] = []
    for (index, benchmarkCase) in cases.enumerated() {
        let prefix = String(format: "  %2d/%2d", index + 1, cases.count)
        do {
            let (output, latency) = try requestRefinement(
                endpoint: endpoint,
                model: model,
                input: benchmarkCase.input
            )
            let catastrophic = isCatastrophic(input: benchmarkCase.input, output: output)
            let exact = output == benchmarkCase.expected
            let constraintsPass =
                benchmarkCase.required.allSatisfy(output.contains) &&
                benchmarkCase.forbidden.allSatisfy { !output.contains($0) } &&
                benchmarkCase.preserved.allSatisfy(output.contains)
            let passed = benchmarkCase.exact ? exact : constraintsPass && !catastrophic
            results.append(.init(
                id: benchmarkCase.id,
                category: benchmarkCase.category,
                input: benchmarkCase.input,
                expected: benchmarkCase.expected,
                output: output,
                passed: passed,
                exact: exact,
                catastrophic: catastrophic,
                latencyMilliseconds: latency,
                error: nil
            ))
            print("\(prefix) \(passed ? "PASS" : "FAIL") \(benchmarkCase.id) \(Int(latency)) ms")
        } catch {
            results.append(.init(
                id: benchmarkCase.id,
                category: benchmarkCase.category,
                input: benchmarkCase.input,
                expected: benchmarkCase.expected,
                output: "",
                passed: false,
                exact: false,
                catastrophic: true,
                latencyMilliseconds: 0,
                error: String(describing: error)
            ))
            print("\(prefix) ERROR \(benchmarkCase.id): \(error)")
        }
    }

    let latencies = results.compactMap { $0.error == nil ? $0.latencyMilliseconds : nil }
    return ModelResult(
        model: model,
        passCount: results.filter(\.passed).count,
        exactCount: results.filter(\.exact).count,
        catastrophicCount: results.filter(\.catastrophic).count,
        correctionPassCount: results.filter { $0.category == "correction" && $0.passed }.count,
        preservationPassCount: results.filter { $0.category == "preservation" && $0.passed }.count,
        medianLatencyMilliseconds: percentile(latencies, 0.5),
        p95LatencyMilliseconds: percentile(latencies, 0.95),
        results: results
    )
}

private func printSummary(_ models: [ModelResult]) {
    print("\nSummary (\(cases.count) cases: 10 correction + 10 exact preservation)")
    print("MODEL                                      PASS   CORR   KEEP  EXACT  BAD  P50 ms  P95 ms")
    print(String(repeating: "-", count: 93))
    for result in models {
        let modelName = String(result.model.prefix(40))
            .padding(toLength: 42, withPad: " ", startingAt: 0)
        let metrics = String(
            format: "%2d/%-2d  %2d/10  %2d/10  %2d/%-2d  %2d  %6.0f  %6.0f",
            result.passCount,
            cases.count,
            result.correctionPassCount,
            result.preservationPassCount,
            result.exactCount,
            cases.count,
            result.catastrophicCount,
            result.medianLatencyMilliseconds,
            result.p95LatencyMilliseconds
        )
        print("\(modelName)\(metrics)")
    }

    print("\nFailed outputs")
    for result in models {
        let failures = result.results.filter { !$0.passed }
        guard !failures.isEmpty else { continue }
        print("\n[\(result.model)]")
        for failure in failures {
            let detail = failure.error ?? failure.output
            print("- \(failure.id): \(detail)")
        }
    }
}

private let endpointString = ProcessInfo.processInfo.environment["OLLAMA_OPENAI_URL"]
    ?? "http://127.0.0.1:11434/v1/chat/completions"
guard let endpoint = URL(string: endpointString) else {
    fputs("Invalid OLLAMA_OPENAI_URL: \(endpointString)\n", stderr)
    exit(2)
}

private let requestedModels = Array(CommandLine.arguments.dropFirst())
private let models = requestedModels.isEmpty ? defaultModels : requestedModels
private let modelResults = models.map { run(model: $0, endpoint: endpoint) }
private let formatter = ISO8601DateFormatter()
private let generatedAt = formatter.string(from: Date())
private let report = BenchmarkReport(
    generatedAt: generatedAt,
    endpoint: endpointString,
    systemPrompt: systemPrompt,
    models: modelResults
)

private let fileFormatter = DateFormatter()
fileFormatter.dateFormat = "yyyyMMdd-HHmmss"
private let reportURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("voicetype-llm-benchmark-\(fileFormatter.string(from: Date())).json")
private let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(report).write(to: reportURL, options: .atomic)

printSummary(modelResults)
print("\nDetailed JSON: \(reportURL.path)")

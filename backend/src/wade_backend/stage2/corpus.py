"""Calibration prompts for estimating J_ℓ (the paper's "pretraining-like distribution", in
miniature). Deliberately varied: prose, code, chat, UI and error text, EN and ES, the kinds of
text Wade's model will read. `VALIDATION` is held out and only used to measure lens quality.
"""

CALIBRATION = [
    "The mitochondria is the organelle responsible for producing most of the cell's chemical energy, in the form of ATP.",
    "In 1492, Columbus crossed the Atlantic and reached the Caribbean, landing first in the Bahamas.",
    "def fibonacci(n):\n    if n < 2:\n        return n\n    return fibonacci(n - 1) + fibonacci(n - 2)",
    "import numpy as np\nx = np.linspace(0, 1, 100)\ny = np.sin(2 * np.pi * x)\nprint(y.mean())",
    "error: cannot find 'ActivityObserver' in scope\n  --> Sources/Wade/WadeApp.swift:42:17",
    "Build Failed: Command CompileSwift failed with a nonzero exit code.",
    "Permission denied (publickey). fatal: Could not read from remote repository.",
    "Hey! Are we still meeting tomorrow at 10? I might be a few minutes late because of traffic.",
    "Thanks for your email. I've attached the updated report and the slides for Thursday's presentation.",
    "To clone the repository, run git clone followed by the URL, then cd into the new folder.",
    "Round trip flights from Bogotá to Los Angeles start at $412. Prices are lower on Tuesdays.",
    "The MacBook Air is thinner and lighter, while the MacBook Pro has more ports and better cooling.",
    "Abstract. We study the effect of attention on memory consolidation in adolescents, using a within-subjects design.",
    "According to the WCAG guidelines, text should have a contrast ratio of at least 4.5 to 1 against its background.",
    "La accesibilidad web busca que las personas con discapacidad puedan usar los sitios sin barreras.",
    "El informe final debe entregarse antes de las 11:59 p. m. del viernes, en formato PDF.",
    "No se pudo guardar el documento porque el disco está lleno.",
    "¿Me puedes enviar el enlace del repositorio? No lo encuentro en el chat.",
    "Once upon a time, in a small village by the sea, there lived an old fisherman and his daughter.",
    "Q: What is the capital of Australia?\nA: The capital of Australia is Canberra, not Sydney.",
    "SELECT name, COUNT(*) FROM orders GROUP BY name HAVING COUNT(*) > 5 ORDER BY 2 DESC;",
    "<button class=\"btn primary\" onclick=\"submitForm()\">Save changes</button>",
    "Settings > Privacy & Security > Accessibility. Click the lock to make changes, then enable the app.",
    "Your session has expired. Please sign in again to continue.",
    "I've been trying to fix this bug for an hour and I still don't understand why the test fails.",
    "The recipe calls for two cups of flour, one teaspoon of salt, and three eggs, beaten.",
    "Stock markets rose on Thursday after the central bank signaled it would keep interest rates unchanged.",
    "user: can you summarize this paragraph for me?\nassistant: Sure. The paragraph argues that",
    "Share this article: Facebook · X · WhatsApp · Copy link",
    "npm ERR! code ERESOLVE\nnpm ERR! ERESOLVE unable to resolve dependency tree",
    "The experiment was repeated three times and the results were averaged to reduce noise.",
    "Photosynthesis converts light energy into chemical energy stored in glucose molecules.",
    "Compare plans: Basic includes 10 GB of storage; Pro includes 1 TB and priority support.",
    "Traceback (most recent call last):\n  File \"main.py\", line 7, in <module>\n    KeyError: 'user_id'",
    "Dear hiring committee, I am writing to apply for the graduate research assistant position.",
    "Let x be a real number such that x^2 = 2. Then x is irrational, as we now show by contradiction.",
    "The movie was slow at first, but the final act made up for it with an unexpected twist.",
    "Download ZIP · Open with GitHub Desktop · Clone using the web URL",
    "Meeting notes: decided to postpone the launch by two weeks; Ana will update the timeline.",
    "Para citar este artículo en formato APA, incluye el autor, el año, el título y la revista.",
    "The weather today is sunny with a high of 31 degrees and a light breeze from the north.",
    "Warning: unused variable 'result' [-Wunused-variable]",
    "Hmm, that didn't work either. Let me try restarting the server and clearing the cache.",
    "The committee reviewed twelve proposals and selected three for funding this year.",
    "func fetch(url: URL) async throws -> Data {\n    let (data, _) = try await URLSession.shared.data(from: url)\n    return data\n}",
    "She opened the laptop, sighed at the unfinished draft, and started typing again.",
    "Frequently asked questions: How do I reset my password? Where can I find my invoices?",
    "Translation: 'Good morning, how are you?' in Spanish is 'Buenos días, ¿cómo estás?'",
]

VALIDATION = [
    "The Great Barrier Reef is the world's largest coral reef system, located off the coast of Queensland.",
    "for i in range(10):\n    if i % 2 == 0:\n        print(i, 'is even')",
    "fatal: not a git repository (or any of the parent directories): .git",
    "Can you send me the slides before the meeting? I want to review them first.",
    "Los resultados muestran una mejora significativa en el tiempo de ejecución de las tareas.",
    "Flights to Madrid are cheapest in February, with average fares around $540 round trip.",
    "The paper proposes a new method for evaluating the accessibility of web content automatically.",
    "I keep getting the same error no matter what I change in the configuration file.",
]


def extended(n: int, seed: int = 0) -> list[str]:
    """`n` calibration prompts for a larger J estimate, built offline (no downloads): the
    hand-written set above, then code and prose (docstrings) sampled from Python's standard
    library: a deterministic, pretraining-like mix of natural language and code."""
    import ast
    import random
    import sysconfig
    from pathlib import Path

    rng = random.Random(seed)
    stdlib = Path(sysconfig.get_paths()["stdlib"])
    files = sorted(p for p in stdlib.glob("*.py") if p.stat().st_size > 4000)
    code: list[str] = []
    prose: list[str] = []
    for path in files:
        try:
            source = path.read_text(encoding="utf-8")
            tree = ast.parse(source)
        except (UnicodeDecodeError, SyntaxError):
            continue
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.ClassDef)):
                doc = ast.get_docstring(node)
                if doc and len(doc) > 200:
                    prose.append(" ".join(doc.split()))
                segment = ast.get_source_segment(source, node)
                if segment and 300 < len(segment) < 3000:
                    code.append(segment)
    rng.shuffle(code)
    rng.shuffle(prose)
    out = list(CALIBRATION)
    while len(out) < n and (code or prose):
        pool = prose if (len(out) % 2 == 0 and prose) or not code else code
        out.append(pool.pop()[:600])
    return out[:n]

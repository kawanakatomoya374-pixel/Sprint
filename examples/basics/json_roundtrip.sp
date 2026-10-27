import json
let doc = json.parse("{\"name\": \"sprint\", \"tags\": [\"fast\", \"small\"], \"stars\": 42}")
doc.stars += 1
print(json.stringify(doc, 2))

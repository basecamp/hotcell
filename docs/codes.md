# Response codes

### Why those two are different

A permanent verdict is only irreversible if the application writes it down. In the shipped Active Storage
integration, analysis does and nothing else does.

Rails persists a blob's analysis like this:

```ruby
# ActiveStorage::Blob::Analyzable
def analyze
  update! metadata: metadata.merge(extract_metadata_via_analyzer)
end

def extract_metadata_via_analyzer
  analyzer.metadata.merge(analyzed: true)
end
```

`analyzed: true` is merged whatever the analyzer returned, including an empty hash. Rails never asks
whether the analysis worked. So the chain is:

1. The blob is attached. Rails enqueues `ActiveStorage::AnalyzeJob`, once.
2. The analyzer calls the cell and gets `killed: memory`, which the client raises as the application's
   permanent class.
3. `Analyzers::Analyzing#metadata` rescues that class, logs it, and returns `{}`.
4. Rails merges `analyzed: true` and writes the row.

The blob's `metadata` is now `{"identified"=>true, "analyzed"=>true}` — analyzed, with no dimensions.
Nothing re-enqueues the job, because `analyze_later` runs once at first attachment.

A transient failure is not rescued at step 3. It escapes into the job, which retries it, and `analyzed`
stays false.

Undoing a permanent one is a backfill:

```ruby
blob.update!(metadata: blob.metadata.except("analyzed"))
blob.analyze_later
```

**Previews and variants write no durable failure record.** `Preview#processed?` is `image.attached?`, and a
variant is recorded by its `active_storage_variant_records` row. A failure attaches nothing and creates
nothing, so the job simply retries. Only analysis needs the generous-first treatment.

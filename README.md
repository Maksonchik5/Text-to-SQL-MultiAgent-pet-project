# Text-to-SQL MultiAgent

Pet project with an agent-based `Text-to-SQL` pipeline for analytical queries to a banking `PostgreSQL` database.

The system takes a user query in natural language, retrieves relevant parts of the DB schema through `RAG`, generates a `read-only SQL` query, executes it, and saves the result to `Excel`.

## What Is Implemented

- Agent workflow on `LangGraph` / `LangChain`
- `RAG` over DB schema with `Chroma`
- Hybrid retrieval: `MMR` + `BM25` + rank fusion
- Schema indexing at table / column / relationship level
- SQL generation through `LLM` with tool calling
- Query execution in `PostgreSQL` through `SQLAlchemy`
- Export of results to `.xlsx`

## Pipeline

`user_query -> RAG -> relevant tables -> schema extraction -> SQL generation -> SQL execution -> Excel export`

## Stack

- `Python`
- `LangChain`, `LangGraph`
- `Chroma`, `BM25Retriever`
- `OpenRouter`, `OpenAIEmbeddings`
- `PostgreSQL`, `SQLAlchemy`
- `Pandas`, `Pydantic`, `PyYAML`

## Project Structure

- [src/main.py](src/main.py) — main graph, RAG, SQL generation and execution
- [src/db_schema.yaml](src/db_schema.yaml) — schema description used for retrieval
- [src/create_bank_db.sql](src/create_bank_db.sql) — initialization of the demo banking database

## Run

1. Install dependencies from `requirements.txt`
2. Create local `PostgreSQL` database `bank_test`
3. Apply:

```bash
psql -d bank_test -f src/create_bank_db.sql
```

4. Set environment variables:

```env
OPENROUTER_API_KEY=...
POSTGRESQL_USER=...
```

5. Start:

```bash
python src/main.py
```

## Resume Summary

Built a multi-agent `Text-to-SQL` system with `LangGraph` and `LangChain`, including `RAG` over database schema, hybrid retrieval, `LLM`-based SQL generation, and execution against `PostgreSQL`.

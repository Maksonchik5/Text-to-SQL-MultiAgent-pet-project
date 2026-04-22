from typing import TypedDict, NotRequired, Annotated, Sequence, List, Any, Tuple, Dict
from pydantic import BaseModel, Field
import pandas as pd
import yaml
from dotenv import load_dotenv
import sqlalchemy
from sqlalchemy import text
from pathlib import Path
import os
import json
from pprint import pprint
from tqdm import tqdm
from functools import lru_cache
import re
load_dotenv()

from langgraph.graph import START, END, StateGraph
from langgraph.graph.message import add_messages
from langchain_core.messages import BaseMessage, AIMessage, HumanMessage, ToolMessage, SystemMessage
from langchain_core.tools import tool
from langgraph.prebuilt import ToolNode
from langchain_openrouter import ChatOpenRouter
from langchain_core.prompts import PromptTemplate
from langchain_core.output_parsers import JsonOutputParser
from langchain_openai import OpenAIEmbeddings
from langchain_core.documents import Document
from langchain_chroma import Chroma
from langchain_community.retrievers import BM25Retriever
from langchain_classic.retrievers.ensemble import EnsembleRetriever

class MultiAgentState(TypedDict):
    messages: NotRequired[Annotated[Sequence[BaseMessage], add_messages]]

    user_query: NotRequired[str]

    rag_top_k: NotRequired[int]

    table_ids: NotRequired[List[str]]
    table_descriptions: NotRequired[List[Dict[str, Any]]]

    sql_status: NotRequired[str] 
    sql_result: NotRequired[Dict]
    sql_error_type: NotRequired[str]
    sql_error_message: NotRequired[str]
    sql_query: NotRequired[str]

    filepath: NotRequired[str]

PROJECT_DIR = Path(__file__).resolve().parent
CHROMA_DIR = PROJECT_DIR / "chroma_langchain_db"

sql_agent_prompt_template = PromptTemplate(
    template=""" 
<summary>
Ты - агент для аналитиков, который по переданному запросу и описанию нужных таблиц Базы Данных пишет корректный sql запрос, отвечающий на запрос пользователя.
В твоих запросах КАТЕГОРИЧЕСКИ ЗАПРЕЩЕНО использовать операции по изменению Базы Данных. 
Твои запросы должны содержать ТОЛЬКО read-only команды.
В твоих запросах должны содержаться ТОЛЬКО переданные таблицы, не придумывай других таблиц.
</summary>

<tools>
Доступные тебе инструменты:
1. sql_execute - инструмент для выполнения sql запроса в Базе данных. На вход принимается корректный запрос sql, а на возвращается Dictionary с полученными данными.
</tools>

<algorithm>
Алгоритм твоих действий:
1. По переданным запросу пользователя и описаниям таблиц сгенерируй корректный sql-запрос.
2. Передай сгенерированный sql-запрос инструменту sql_execute и получи Dictionary.
</algorithm>

<db_schema>
{schema}
</db_schema>

<warning>
В SQL запросах спользуй ТОЛЬКО те таблицы, которые находятся в table_descriptions.
КАТЕГОРИЧЕСКИ ЗАПРЕЩЕНО додумывать столбцы или новые таблицы.
Если результат sql_execute содержит ошибку, не придумывай новые таблицы и столбцы.
Работай только с теми таблицами и столбцами, которые явно перечислены в schema.
</warning>
    """,
    input_variables=['schema']
)

engine = sqlalchemy.create_engine(
            f'postgresql://{os.getenv("POSTGRESQL_USER")}@localhost:5432/bank_test'
)

def load_schema() -> Dict:
    with open(PROJECT_DIR / 'db_schema.yaml') as tables:
        schema = yaml.safe_load(tables)
    return schema

def create_docs_from_yaml(schema: Dict) -> Tuple[List[Document], List]:
    docs = []
    ids = []
    for table in schema['tables']:
        table_id = table['table_id']
        table_name = table.get('table_name', table_id)
        table_description = table.get('description', '')
        columns = table.get('columns', [])
        table_columns_list = []

        for column in columns:
            column_name = column['name']
            column_description = column.get('description', '')
            column_type = column.get('type', '')

            table_columns_list.append(column_name)

            column_doc = Document(
                page_content=(
                    f'Колонка {table_id}.{column_name}.\n'
                    f'Таблица {table_id}.\n'
                    f'Описание таблицы: {table_description}.\n'
                    f'Описание колонки: {column_description}.\n'
                    f'Тип данных: {column_type}.'
                ),
                metadata={
                    'doc_type': 'column',
                    'table_id': table_id,
                    'table_name': table_name,
                    'column_name': column_name,
                    'column_type': column_type
                }
            )

            docs.append(column_doc)
            ids.append(f'column:{table_id}.{column_name}')

            foreign_key = column.get('foreign_key')
            if foreign_key:
                to_table, to_column = foreign_key.split('.')

                relationship_doc = Document(
                    page_content=(
                        f'Связь {table_id}.{column_name}->{to_table}.{to_column}.\n'
                        f'Таблица {table_id} связана с таблицей {to_table}.'
                    ),
                    metadata={
                        'doc_type': 'relationship',
                        'table_id': table_id,
                        'from_table': table_id,
                        'from_column': column_name,
                        'to_table': to_table,
                        'to_column': to_column
                    }
                )

                docs.append(relationship_doc)
                ids.append(f'relationship:{table_id}.{column_name}->{to_table}.{to_column}')

        table_doc = Document(
            page_content=(
                f'Таблица {table_id}.\n'
                f'Описание: {table_description}.\n'
                f'Колонки: {", ".join(table_columns_list)}.'
            ),
            metadata={
                'doc_type': 'table',
                'table_id': table_id,
                'table_name': table_name,
                'columns': ', '.join(table_columns_list)
            }
        )
        
        docs.append(table_doc)
        ids.append(f'table:{table_id}')
    return docs, ids

def get_embeddings() -> OpenAIEmbeddings:
    embedding_model = OpenAIEmbeddings(
        model='openai/text-embedding-3-small',
        base_url='https://openrouter.ai/api/v1',
        api_key=os.getenv("OPENROUTER_API_KEY")
    )
    return embedding_model

def get_chroma_db() -> Chroma:
    return Chroma(
        collection_name='bank_test',
        embedding_function=get_embeddings(),
        persist_directory=str(CHROMA_DIR)
    )

def rebuild_chroma_db() -> None:
    chroma_db = get_chroma_db()

    existing = chroma_db.get(include=[])
    existing_ids = existing['ids']

    if existing_ids:
        chroma_db.delete(ids=existing_ids)

    create_chroma_db(chroma_db)

    get_hybrid_retriever.cache_clear()

def create_chroma_db(chroma_db: Chroma | None = None) -> None:
    if not chroma_db:
        chroma_db = get_chroma_db()

    schema = load_schema()
    docs, ids = create_docs_from_yaml(schema)

    chroma_db.add_documents(documents=docs, ids=ids)

def build_hybrid_retriever(top_k: int = 10) -> EnsembleRetriever:
    chroma_db = get_chroma_db()

    if chroma_db._collection.count() == 0:
        create_chroma_db(chroma_db)

    docs = []
    items = chroma_db.get(include=['documents', 'metadatas'])
    for doc_id, page_content, metadata in zip(
        items['ids'],
        items["documents"],
        items["metadatas"]
    ):
        docs.append(Document(
            page_content=page_content,
            metadata=metadata or {},
            id=doc_id
        ))
    
    if not docs:
        raise ValueError(
            "Chroma collection is empty. Run create_rag_db() first."
        )

    bm25_retriever = BM25Retriever.from_documents(documents=docs, k=top_k)

    mmr_retriever = chroma_db.as_retriever(
        search_type='mmr',
        search_kwargs={
            'k': top_k,
            'fetch_k': top_k*2,
            'lambda_mult': 0.5
        }
    )

    ensemble_retriever = EnsembleRetriever(
        retrievers=[mmr_retriever, bm25_retriever],
        weights=[0.7, 0.3]
    )

    return ensemble_retriever

@lru_cache(maxsize=1)
def get_hybrid_retriever(top_k: int = 10):
    return build_hybrid_retriever(top_k=top_k)

def parse_rag_output(rag_output: List[Document]) -> List[str]:
    relevant_tables = set()

    # table_pattern = re.compile(r'^table:(\w+)$')
    # column_pattern = re.compile(r'^column:(\w+)\.(\w+)$')
    # relationship_pattern = re.compile(r'^relationship:(\w+)\.(\w+)->(\w+)\.(\w+)$')

    # for doc in rag_output:
    #     doc_id = doc.id

    #     if not doc_id:
    #         continue

    #     table_match = table_pattern.search(doc_id)
    #     column_match = column_pattern.search(doc_id)
    #     relationship_match = relationship_pattern.search(doc_id)

    #     if table_match:
    #         relevant_tables.add(table_match.group(1))
    #     elif column_match:
    #         relevant_tables.add(column_match.group(1))
    #     elif relationship_match:
    #         relevant_tables.add(relationship_match.group(1))
    #         relevant_tables.add(relationship_match.group(3))

    for doc in rag_output:
        metadata = doc.metadata or {}
        table_id = metadata.get('table_id')
        if table_id:
            relevant_tables.add(table_id)
        
        from_table = metadata.get('from_table')
        if from_table:
            relevant_tables.add(from_table)

        to_table = metadata.get('to_table')
        if to_table:
            relevant_tables.add(to_table)

    return list(relevant_tables)

def rag(state: MultiAgentState) -> MultiAgentState:
    """Найти нужные таблицы для ответа на запрос пользователя"""
    user_query = state['user_query']
    new_messages = state.get('messages', []) + [HumanMessage(content=user_query)]
    top_k = state.get('rag_top_k', 10)

    hybrid_retriever = get_hybrid_retriever(top_k=top_k)

    rag_result = hybrid_retriever.invoke(user_query)[:top_k]

    table_ids = parse_rag_output(rag_result)

    return {'table_ids': table_ids, 'messages': new_messages}


def extract_tables_description(state: MultiAgentState) -> MultiAgentState:
    """Получение описания столбцов необходимых таблиц"""

    with open(PROJECT_DIR / 'db_schema.yaml') as table_description_file:
        schema = yaml.safe_load(table_description_file)

    table_descriptions = []
    
    for table in schema['tables']:
        if table['table_id'] in state['table_ids']:
            table_descriptions.append(table)

    return {'table_descriptions': table_descriptions}


@tool
def sql_execute(query: str) -> Dict:
    """Подключение к Базе данных и выполнение запроса query"""
    try:

        with engine.connect() as conn:
            df = pd.read_sql(query, conn)
        
        data = df.to_dict('records')

        return {'sql_result': data}

    except Exception as e:
        return {
            'status': 'error',
            'error_type': type(e).__name__,
            'error_message': str(e),
            'query': query
        }

sql_agent_tools = [sql_execute]

sql_llm = ChatOpenRouter(
    model='qwen/qwen3-235b-a22b-2507',
    api_key=os.getenv("OPENROUTER_API_KEY")
).bind_tools(sql_agent_tools)

def generate_sql(state: MultiAgentState) -> MultiAgentState:
    tables_description = state.get('table_descriptions', [])

    table_schema = '\n\n'.join([
            f"Table: {t['table_id']}\n" +
            '\n'.join([f"  - {c['name']} ({c['type']}): {c.get('description', '')}" 
                    for c in t['columns']])
            for t in tables_description
        ])

    sql_system_prompt = sql_agent_prompt_template.format(schema=table_schema)

    result = sql_llm.invoke(input=[SystemMessage(content=sql_system_prompt), state['user_query']])
    new_messages = state.get('messages', []) + [result]
    return {'messages': new_messages}

def should_sql_continue(state: MultiAgentState) -> str:
    last_message = state['messages'][-1]
    if last_message.tool_calls:
        return 'tool'
    return 'end'

def shoul_regenerate_sql(state: MultiAgentState) -> str:
    last_message = state['messages'][-1]
    if isinstance(last_message, ToolMessage):
        sql_result = json.loads(last_message.content).get('sql_result', {})
        if len(sql_result) > 0:
            return 'save_to_excel'
        else:
            return 'regenerate'
    return 'regenerate'

def save_to_excel(state: MultiAgentState) -> MultiAgentState:
    """Сохранение результатов запроса в Excel файл"""

    last_message = state['messages'][-1]
    sql_result = json.loads(last_message.content).get('sql_result', {})
    user_query = state['user_query']
    df = pd.DataFrame(sql_result)

    dirname = Path.cwd() / 'output'
    dirname.mkdir(exist_ok=True)

    filepath = dirname / f'result_{abs(hash(user_query)) % 10000}.xlsx'

    df.to_excel(filepath, index=False)

    return {'filepath': str(filepath), 'sql_result': sql_result}

def main():
    graph = StateGraph(MultiAgentState)

    graph.add_node('rag', rag)
    graph.add_node('extract_tables_description', extract_tables_description)
    graph.add_node('generate_sql', generate_sql)
    sql_tools = ToolNode(sql_agent_tools)
    graph.add_node('sql_tools', sql_tools)
    graph.add_node('save_to_excel', save_to_excel)

    graph.set_entry_point('rag')
    graph.add_edge('rag', 'extract_tables_description')
    graph.add_edge('extract_tables_description', 'generate_sql')
    graph.add_conditional_edges(
        'generate_sql',
        should_sql_continue,
        {'tool': 'sql_tools', 'end': END}
    )
    graph.add_conditional_edges(
        'sql_tools',
        shoul_regenerate_sql,
        {'regenerate': 'generate_sql', 'save_to_excel': 'save_to_excel'}
    )
    graph.add_edge('save_to_excel', END)

    return graph.compile()

if __name__ == '__main__':
    app = main()
    user_input = input('Ваш запрос: ')
    result = app.invoke({'user_query': user_input})
    pprint(result)

from typing import TypedDict, NotRequired, Annotated, Sequence, List
from pydantic import BaseModel, Field
import pandas as pd
import yaml
from dotenv import load_dotenv
import sqlalchemy
from pathlib import Path
import os
import json
from pprint import pprint
load_dotenv()

from langgraph.graph import START, END, StateGraph
from langgraph.graph.message import add_messages
from langchain_core.messages import BaseMessage, AIMessage, HumanMessage, ToolMessage, SystemMessage
from langchain_core.tools import tool
from langgraph.prebuilt import ToolNode
from langchain_openrouter import ChatOpenRouter
from langchain_core.prompts import PromptTemplate
from langchain_core.output_parsers import JsonOutputParser



class MultiAgentState(TypedDict):
    messages: NotRequired[Annotated[Sequence[BaseMessage], add_messages]]
    sql_messages: NotRequired[Annotated[Sequence[BaseMessage], add_messages]]
    query: NotRequired[str]
    table_ids: NotRequired[List[str]]
    table_descriptions: NotRequired[List[str]]
    sql_result: NotRequired[dict]
    filepath: NotRequired[str]


class RAGOutput(BaseModel):
    table_ids: List[str] = Field(description='Список ID таблиц')


class SQLQuery(BaseModel):
    sql_query: str = Field(description='SQL запрос для выполнения')
    description: str = Field(description='Объяснение, что делает запрос')
    tables_used: List[str] = Field(description='Список используемых таблиц')
    filepath: str = Field(description='Путь до Excel файла с данными')


main_agent_system_prompt = """
<summary>
Ты - агент для аналитиков, который упрощает отвечает на вопросы по данным из банковской Базы Данных. 
Твоя задача с помощью доступных тебе инструментов получить ответ на вопрос пользователя в виде пути к Excel-файлу с нужными данными.
</summary>

<tools>
Доступные тебе инструменты:
1. RAG tool - инструмент, который по запросу пользователя выдает id самых релевантных таблиц для ответа на вопрос.
2. Extract Table Descriptions - инструмент, который по переданному ему списку id таблиц вовзращает описание нужных таблиц.
</tools>

<algorithm>
Алгоритм твоих действий:
1. Передать запрос пользователя в RAG tool и получить из него id таблиц Базы Данных.
2. Передать полученные на прошлом шаге id в инструмент Extract Table Descriptions и получить описание нужных таблиц.
3. Передать полученное описание SQL агенту, не нужно его вызывать, просто заверши работу.
</algorithm>
"""


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
2. save_to_excel - инструмент для сохранения полученных данных в Excel файл. На вход подается pandas DataFrame, а на возвращается Dictionary с путем до файла.
</tools>

<algorithm>
Алгоритм твоих действий:
1. По переданным запросу пользователя и описаниям таблиц сгенерируй корректный sql-запрос.
2. Передай сгенерированный sql-запрос инструменту sql_execute и получи Dictionary.
3. Передай полученный Dictionary в инструмент save_to_excel и получи путь до сохраненного файла.
</algorithm>

<db_schema>
{schema}
</db_schema>

<user_query>
{user_query}
</user_query>

<warning>
В SQL запросах спользуй ТОЛЬКО те таблицы, которые находятся в table_descriptions.
КАТЕГОРИЧЕСКИ ЗАПРЕЩЕНО додумывать столбцы или новые таблицы.
</warning>
    """,
    input_variables=['schema', 'user_query']
)


@tool
def rag_tool(query: str) -> RAGOutput:
    """Найти нужные таблицы для ответа на запрос пользователя"""
    table_ids = 'customers'

    return {'table_ids': [table_ids]}


@tool
def extract_table_descriptions(table_ids: List[str]) -> dict:
    """Получение описания столбцов необходимых таблиц"""

    with open('db_schema.yaml') as table_description_file:
        schema = yaml.safe_load(table_description_file)

    table_descriptions = []
    
    for table in schema['tables']:
        if table['table_id'] in table_ids:
            table_descriptions.append(table)

    return {'table_descriptions': table_descriptions}


@tool
def sql_execute(query: str) -> dict:
    """Подключение к Базе данных и выполнение запроса query"""
    try:
        engine = sqlalchemy.create_engine(
            f'postgresql://{os.getenv("POSTGRESQL_USER")}:{os.getenv("POSTGRESQL_PASSWORD")}@localhost:5432/bank_test'
        )

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


@tool
def save_to_excel(user_query: str, df: dict) -> dict:
    """Сохранение результатов запроса в Excel файл"""

    df = pd.DataFrame(df)

    dirname = Path.cwd() / 'output'
    dirname.mkdir(exist_ok=True)

    filepath = dirname / f'result_{abs(hash(user_query)) % 10000}.xlsx'

    df.to_excel(filepath, index=False)

    return {'filepath': str(filepath)}


main_agent_tools = [rag_tool, extract_table_descriptions]
sql_agent_tools = [sql_execute, save_to_excel]


main_llm = ChatOpenRouter(
    model='qwen/qwen3-235b-a22b-2507',
    api_key=os.getenv("OPENROUTER_API_KEY")
).bind_tools(main_agent_tools)

sql_llm = ChatOpenRouter(
    model='qwen/qwen3-235b-a22b-2507',
    api_key=os.getenv("OPENROUTER_API_KEY")
).bind_tools(sql_agent_tools)


def model_call(state: MultiAgentState) -> dict:
    returned_dict = {}

    if len(state.get('messages', [])) > 0:
        last_message = state['messages'][-1]
        if isinstance(last_message, ToolMessage) and last_message.name == 'extract_table_descriptions':
            table_descriptions = json.loads(last_message.content)
            returned_dict['table_descriptions'] = table_descriptions['table_descriptions']
        
        elif isinstance(last_message, ToolMessage) and last_message.name == 'rag_tool':
            returned_dict['table_ids'] = json.loads(last_message.content)['table_ids']
            

    if len(state.get('messages', [])) == 0:
        query = input('Вы: ')
        returned_dict['query'] = query

        new_messages = [SystemMessage(content=main_agent_system_prompt)] + [HumanMessage(content=query)]
    else:
        new_messages = state.get('messages', [])
        
    response = main_llm.invoke(new_messages)

    returned_dict['messages'] = new_messages + [response]

    return returned_dict


def need_tools(state: MultiAgentState) -> str:
    last_message = state.get('messages', [])[-1]

    if isinstance(last_message, AIMessage) and last_message.tool_calls:
        return 'tool'
    return 'continue'


def call_sql_agent(state: MultiAgentState) -> dict: 
    returned_dict = {}   
    sql_chain = sql_agent_prompt_template | sql_llm

    if len(state.get('sql_messages', [])) > 0:
        last_message = state['sql_messages']
        if isinstance(last_message, ToolMessage) and last_message.name == 'sql_execute':
            returned_dict['sql_result'] = json.loads(last_message.content)['sql_result']
        elif isinstance(last_message, ToolMessage) and last_message.name == 'save_to_excel':
            returned_dict['filepath'] = json.loads(last_message.content)['filepath']
    if len(state.get('sql_messages', [])) == 0:
        user_query = state.get('query', '')
        table_descriptions = state.get('table_descriptions', [])

        table_schema = '\n\n'.join([
            f"Table: {t['table_id']}\n" +
            '\n'.join([f"  - {c['name']} ({c['type']}): {c.get('description', '')}" 
                    for c in t['columns']])
            for t in table_descriptions
        ])

        response = sql_chain.invoke({'schema': table_schema, 'user_query': user_query})
    else:
        messages = state['sql_messages']
        response = sql_llm.invoke(messages)
    
    returned_dict['response'] = response
    return returned_dict


def need_sql_tools(state: MultiAgentState) -> str:
    last_message = state['sql_messages'][-1] if state.get('sql_messages') else None
    
    if last_message is None:
        return 'continue'
    
    if isinstance(last_message, AIMessage) and last_message.tool_calls:
        return 'tool'
    
    if isinstance(last_message, ToolMessage):
        if last_message.name == 'save_to_excel':
            return 'continue'
        elif last_message.name == 'sql_execute':
            return 'tool'
    
    return 'continue'


graph = StateGraph(MultiAgentState)

graph.add_node('model_call', model_call)
main_agent_tools_node = ToolNode(tools=main_agent_tools)
graph.add_node('main_agent_tools', main_agent_tools_node)
graph.add_node('call_sql_agent', call_sql_agent)
sql_agents_tools_node = ToolNode(tools=sql_agent_tools)
graph.add_node('sql_agent_tools', sql_agents_tools_node)

graph.add_edge(START, 'model_call')
graph.add_conditional_edges(
    "model_call", 
    need_tools, 
    {
        'tool': 'main_agent_tools',
        'continue': 'call_sql_agent'
    }
)
graph.add_edge('main_agent_tools', 'model_call')
graph.add_conditional_edges(
    'call_sql_agent',
    need_sql_tools,
    {
        'tool': 'sql_agent_tools',
        'continue': END
    }
)
graph.add_edge('sql_agent_tools', 'call_sql_agent')

app = graph.compile()

if __name__ == '__main__':
    result = app.invoke({})
    pprint(result)

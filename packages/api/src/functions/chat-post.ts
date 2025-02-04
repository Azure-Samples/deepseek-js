import process from 'node:process';
import { Readable } from 'node:stream';
import { type IncomingMessage } from 'node:http';
import { DefaultAzureCredential } from '@azure/identity';
import { type HttpRequest, type InvocationContext, type HttpResponseInit, app } from '@azure/functions';
import {
  type AIChatCompletionRequest,
  type AIChatCompletionDelta,
  type AIChatCompletion,
} from '@microsoft/ai-chat-protocol';
import ModelClient, { isUnexpected } from '@azure-rest/ai-inference';
import { createSseStream } from '@azure/core-sse';
import 'dotenv/config';

const credentialScopes = { credentials: { scopes: ['https://cognitiveservices.azure.com/.default'] } };
const systemPrompt = `Assistant helps the user with cooking questions. Be brief in your answers. Answer only plain text, DO NOT use Markdown.

After your answer, ALWAYS generate 3 very brief follow-up questions that the user would likely ask next, based on the context.
Enclose the follow-up questions in double angle brackets. Example:
<<What ingredients I need to bake cookies?>>
<<What flavour can I use in my cookies?>>
<<How long should I put it in the oven?>>

Do no repeat questions that have already been asked.
Make sure the last question ends with ">>".
`;

export async function postChat(
  stream: boolean,
  request: HttpRequest,
  context: InvocationContext,
): Promise<HttpResponseInit> {
  try {
    const requestBody = (await request.json()) as AIChatCompletionRequest;
    const { messages } = requestBody;

    if (!messages || messages.length === 0 || !messages.at(-1)?.content) {
      return {
        status: 400,
        body: 'Invalid or missing messages in the request body',
      };
    }

    const model = process.env.AZURE_AI_DEPLOYMENT_NAME;
    const endpoint = process.env.AZURE_AI_ENDPOINT;
    if (!model || !endpoint) {
      return {
        status: 500,
        body: 'Missing required environment variables',
      };
    }

    context.log(`Using AI model: ${model} at ${endpoint}`);

    // Use the current user identity to authenticate.
    // No secrets needed, it uses `az login` or `azd auth login` locally,
    // and managed identity when deployed on Azure.
    const credentials = new DefaultAzureCredential();
    const client = ModelClient(endpoint, credentials, credentialScopes);

    if (stream) {
      const responseStream = await client
        .path('/chat/completions')
        .post({
          body: {
            messages: [{ role: 'system', content: systemPrompt }, ...messages],
            temperature: 0.7,
            model,
            stream: true,
          },
        })
        .asNodeStream();

      const stream = responseStream.body as IncomingMessage;
      if (!stream) {
        throw new Error('The response stream is undefined');
      }

      if (responseStream.status !== '200') {
        throw new Error('Failed to get chat completions');
      }

      const jsonStream = Readable.from(createJsonStream(stream));
      return {
        headers: {
          'Content-Type': 'application/x-ndjson',
          'Transfer-Encoding': 'chunked',
        },
        body: jsonStream,
      };
    }

    const response = await client.path('/chat/completions').post({
      body: {
        messages: [{ role: 'system', content: systemPrompt }, ...messages],
        temperature: 0.7,
        model,
      },
    });

    if (isUnexpected(response)) {
      throw new Error(response.body.error.message);
    }

    return {
      jsonBody: {
        message: {
          content: response.body.choices[0].message.content,
          role: 'assistant',
        },
      } as AIChatCompletion,
    };
  } catch (_error: unknown) {
    const error = _error as Error;
    context.error(`Error when processing chat-post request: ${error.message}`);

    return {
      status: 500,
      body: 'Service temporarily unavailable. Please try again later.',
    };
  }
}

// Transform the SSE stream into a JSON stream
async function* createJsonStream(stream: IncomingMessage) {
  const events = createSseStream(stream);

  for await (const event of events) {
    if (event.data === '[DONE]') return;
    if (!event.data) continue;

    const chunk = JSON.parse(event.data);
    if (!chunk.choices[0]?.delta.content) continue;

    const responseChunk: AIChatCompletionDelta = {
      delta: {
        content: chunk.choices[0].delta.content as string,
        role: 'assistant',
      },
    };

    // Format response chunks in Newline delimited JSON
    // see https://github.com/ndjson/ndjson-spec
    yield JSON.stringify(responseChunk) + '\n';
  }
}

app.setup({ enableHttpStream: true });
app.http('chat-stream-post', {
  route: 'chat/stream',
  methods: ['POST'],
  authLevel: 'anonymous',
  handler: postChat.bind(null, true),
});
app.http('chat-post', {
  route: 'chat',
  methods: ['POST'],
  authLevel: 'anonymous',
  handler: postChat.bind(null, false),
});

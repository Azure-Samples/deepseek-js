import { type HTMLTemplateResult, html, nothing } from 'lit';
import { AIChatMessage } from '@microsoft/ai-chat-protocol';

export type ParsedMessage = {
  html: HTMLTemplateResult;
  citations: string[];
  followupQuestions: string[];
  role: string;
  context?: object;
  thoughts?: HTMLTemplateResult;
  hasContent?: boolean;
};

export function parseMessageIntoHtml(
  message: AIChatMessage,
  renderCitationReference: (citation: string, index: number) => HTMLTemplateResult,
): ParsedMessage {
  if (message.role === 'user') {
    return {
      html: html`${message.content}`,
      citations: [],
      followupQuestions: [],
      role: message.role,
      context: message.context,
      hasContent: true,
    };
  }

  let thoughts = '';
  const citations: string[] = [];
  const followupQuestions: string[] = [];

  // Extract any thoughts that might be in the message, between <think> tags
  let text = message.content
    .replaceAll(/<think>(.*?)(<\/think>|$)/gs, (_match, content) => {
      thoughts = content;
      return '';
    })
    .trim();

  // Extract any follow-up questions that might be in the message
  text = text
    .replaceAll(/<<([^>]+)>>/g, (_match, content: string) => {
      followupQuestions.push(content);
      return '';
    })
    .split('<<')[0] // Truncate incomplete questions
    .trim();

  // Extract any citations that might be in the message
  const parts = text.split(/\[([^\]]+)]/g);
  const result = html`${parts.map((part, index) => {
    if (index % 2 === 0) {
      return html`${part}`;
    }

    if (index + 1 < parts.length) {
      // Handle only completed citations
      let citationIndex = citations.indexOf(part);
      if (citationIndex === -1) {
        citations.push(part);
        citationIndex = citations.length;
      } else {
        citationIndex++;
      }

      return renderCitationReference(part, citationIndex);
    }

    return nothing;
  })}`;

  return {
    html: result,
    citations,
    thoughts: html`${thoughts}`,
    followupQuestions,
    role: message.role,
    context: message.context,
    hasContent: text.length > 0,
  };
}

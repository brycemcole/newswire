export const freeModel = 'deepseek-v4.1-flash-free';
export const goModel = 'deepseek-v4.1-flash';

export class AIError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

type Job = { id: string; body: Record<string, unknown>; claimed: boolean; finish: (response: Response) => void };

export class AIBroker {
  private jobs = new Map<string, Job>();
  private workerSeen = 0;
  private notify?: () => void;

  status() { return { model: freeModel, context: 200000, available: Date.now() - this.workerSeen < 45000, pending: this.jobs.size }; }

  async complete(body: Record<string, unknown>, signal: AbortSignal): Promise<Response> {
    if (!this.status().available) throw new AIError(503, 'Free DeepSeek is temporarily unavailable. Try again shortly.');
    if (body.model !== undefined && body.model !== freeModel) throw new AIError(400, 'Only the free DeepSeek model is available');
    if (!Array.isArray(body.messages) || !body.messages.length || body.messages.length > 100) throw new AIError(400, 'Expected 1-100 messages');
    for (const message of body.messages) {
      if (!message || !['system', 'user', 'assistant', 'tool'].includes(message.role) || (typeof message.content !== 'string' && !(message.role === 'assistant' && Array.isArray(message.tool_calls)))) throw new AIError(400, 'Invalid AI message');
    }
    if (body.tools !== undefined && (!Array.isArray(body.tools) || body.tools.length > 100 || body.tools.some(tool => tool?.type !== 'function' || !/^[\w-]{1,80}$/.test(tool.function?.name) || typeof tool.function?.parameters !== 'object'))) throw new AIError(400, 'Invalid AI tools');
    if (body.tool_choice !== undefined && !['auto', 'none'].includes(String(body.tool_choice))) throw new AIError(400, 'Invalid tool_choice');
    const max = body.max_tokens ?? 1800;
    if (!Number.isInteger(max) || Number(max) < 1 || Number(max) > 16000) throw new AIError(400, 'Invalid max_tokens');
    if (this.jobs.size >= 12) throw new AIError(429, 'Free DeepSeek is busy. Try again shortly.');
    if (signal.aborted) throw new AIError(499, 'Request cancelled');
    return new Promise(resolve => {
      const id = crypto.randomUUID();
      const finish = (response: Response) => {
        clearTimeout(timer);
        signal.removeEventListener('abort', abort);
        this.jobs.delete(id);
        resolve(response);
      };
      const abort = () => finish(Response.json({ error: { message: 'Request cancelled' } }, { status: 499 }));
      const timer = setTimeout(() => finish(Response.json({ error: { message: 'Free DeepSeek timed out. Try again.' } }, { status: 504 })), 85000);
      signal.addEventListener('abort', abort, { once: true });
      this.jobs.set(id, { id, body: { messages: body.messages, tools: body.tools, tool_choice: body.tool_choice, max_tokens: max, model: freeModel }, claimed: false, finish });
      this.notify?.();
    });
  }

  async claim() {
    this.workerSeen = Date.now();
    if (![...this.jobs.values()].some(job => !job.claimed)) {
      await new Promise<void>(resolve => {
        const wake = () => { clearTimeout(timer); if (this.notify === wake) this.notify = undefined; resolve(); };
        const timer = setTimeout(wake, 15000);
        this.notify?.();
        this.notify = wake;
      });
    }
    this.workerSeen = Date.now();
    const job = [...this.jobs.values()].find(job => !job.claimed);
    if (!job) return { job: null };
    job.claimed = true;
    return { job: { id: job.id, body: job.body } };
  }

  result(body: Record<string, unknown>) {
    const job = this.jobs.get(String(body.id));
    if (!job?.claimed) throw new AIError(404, 'AI request expired');
    if (body.error) job.finish(Response.json({ error: { message: 'Free DeepSeek could not finish this request. Try again.' } }, { status: 502 }));
    else {
      const result = body.result as { model?: string; provider?: string; billing?: string; choices?: unknown[]; cost?: number } | undefined;
      const free = result?.model === freeModel && result.cost === 0;
      const go = result?.model === goModel && result.provider === 'opencode-go' && result.billing === 'subscription' && result.cost === undefined;
      if ((!free && !go) || !Array.isArray(result?.choices) || result.choices.length !== 1) throw new AIError(400, 'Invalid AI result');
      job.finish(Response.json(result));
    }
    return { accepted: true };
  }
}

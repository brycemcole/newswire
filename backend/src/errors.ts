export class DataError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

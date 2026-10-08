// Only controlled explanations from this class are exposed in import receipts.
export class ImportFailure extends Error {
  constructor(
    message: string,
    public terminal = true,
  ) {
    super(message);
  }
}

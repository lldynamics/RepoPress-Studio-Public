export type ExitActivityErrorCode = "exit_in_progress" | "exit_busy";

type ExitActivityError = Error & { code: ExitActivityErrorCode };

function createExitActivityError(code: ExitActivityErrorCode): ExitActivityError {
  const error = new Error(code) as ExitActivityError;
  error.code = code;
  return error;
}

/** Coordinates native work with the short synchronous freeze used by safe exit. */
export class ExitActivityGate {
  private pendingCount = 0;
  private activeLease: symbol | undefined;

  get busy(): boolean {
    return this.pendingCount > 0;
  }

  get frozen(): boolean {
    return this.activeLease !== undefined;
  }

  run<T>(work: () => Promise<T>): Promise<T> {
    if (this.frozen) {
      return Promise.reject(createExitActivityError("exit_in_progress"));
    }

    this.pendingCount += 1;
    try {
      return Promise.resolve(work()).finally(() => {
        this.pendingCount -= 1;
      });
    } catch (error) {
      this.pendingCount -= 1;
      return Promise.reject(error);
    }
  }

  freeze(): () => void {
    if (this.busy || this.frozen) {
      throw createExitActivityError("exit_busy");
    }

    const lease = Symbol("exit-freeze");
    this.activeLease = lease;
    let released = false;
    return () => {
      if (released) {
        return;
      }
      released = true;
      if (this.activeLease === lease) {
        this.activeLease = undefined;
      }
    };
  }
}

export const exitActivity = new ExitActivityGate();

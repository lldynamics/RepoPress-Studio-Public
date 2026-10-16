export class LatestPreferenceSelection<T> {
  private generation = 0;
  private desiredValue: T | undefined;
  private hasDesiredValue = false;

  current(persistedValue: T): T {
    return this.hasDesiredValue ? this.desiredValue as T : persistedValue;
  }

  request(nextValue: T, persistedValue: T): number | null {
    if (Object.is(nextValue, this.current(persistedValue))) return null;
    this.desiredValue = nextValue;
    this.hasDesiredValue = true;
    return ++this.generation;
  }

  settle(requestGeneration: number): boolean {
    if (requestGeneration !== this.generation) return false;
    this.desiredValue = undefined;
    this.hasDesiredValue = false;
    return true;
  }
}

export {};

declare global {
  interface Window {
    __cydoE2e?: {
      fork?: (tid: number, afterUuid: string) => void;
    };
  }
}

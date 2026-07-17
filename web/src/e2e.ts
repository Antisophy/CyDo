export {};

declare global {
  interface Window {
    __cydoE2e?: {
      fork?: (tid: number, afterUuid: string) => void;
      undo?: (
        tid: number,
        afterUuid: string,
        dryRun: boolean,
        revertConversation: boolean,
        revertFiles: boolean,
      ) => void;
    };
  }
}

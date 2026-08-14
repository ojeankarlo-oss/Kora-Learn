import { createContext, useContext } from "react";
import { TEMA_PADRAO } from "./theme";

export const TemaContext = createContext(TEMA_PADRAO);

export function useTema() {
  return useContext(TemaContext);
}

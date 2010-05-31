/*
 * Uses the quick sort algorithm to sort a linked list.  Works recursively
 * and returns a pointer to the last element so the lists can be linked back
 * up without walking to find the end.  The list must use a NULL ptr as an
 * indicator of the last element.
 *
 * base = top of list.
 * next = function to return next item in list or NULL (must return a void **).
 * cmp  = function which must return a negative value if e1 is less than e2,
 *	zero if the two are equal, or a positive value if e1 is greater than
 *	e2.
 */
#define BASE (*base)
#define NEXT(elem) (*(*next(elem)))
#define CMP(e1,e2) ((*cmp)((e1), (e2)) < 0)
void *qsort_list(void **base, void **(*next)(void *elem),
		    int (*cmp)(const void *e1, const void *e2))
{
  void *left = NULL, *right = NULL, *pivot, *leftend, *rightend, *ptr, *n_ptr;

  if (!BASE || !NEXT(BASE))
    return base;

  rightend = pivot = BASE;

  /* divide the elements to two lists according to the pivot point. */
  for (ptr = NEXT(pivot); ptr; ptr = n_ptr) {
    n_ptr = NEXT(ptr);

    if (CMP(ptr, pivot)) {
      NEXT(ptr) = left;
      left = ptr;
    } else {
      NEXT(ptr) = right;
      right = ptr;
    }
  }

  /* Now we just recursively call qsort_list() for each half. */
  if (left) {
    leftend = qsort_list(&left, next, cmp);
    BASE = left;
    NEXT(leftend) = pivot;
  }
  if (right) {
    rightend = qsort_list(&right, next, cmp);
    NEXT(pivot) = right;
  }

  /* Terminate the list. */
  NEXT(rightend) = NULL;

  return rightend;
}
#undef BASE
#undef NEXT
#undef CMP

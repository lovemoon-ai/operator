import { EnrollAgent } from "./EnrollAgent";

export const dynamic = "force-dynamic";

export default async function EnrollPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return <EnrollAgent enrollmentId={id} />;
}
